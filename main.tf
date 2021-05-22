data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

provider "aws" {
  profile = "default"
  region  = var.aws_region
}

### Start of VPC block #############

resource "aws_vpc" "first_vpc" {
    cidr_block = "10.1.0.0/16"
    enable_dns_hostnames = true
    enable_dns_support = true
    tags = {
      "Name" = "wordpress-vpc-1"
    }
}

resource "aws_subnet" "sbnt-vpc1" {
    vpc_id     = aws_vpc.first_vpc.id
    cidr_block = "10.1.1.0/24"
    availability_zone = data.aws_availability_zones.available.names[0]
    tags = {
    Name = "wordpress-sbnt-1"
}
}

resource "aws_subnet" "sbnt-vpc2" {
    vpc_id     = aws_vpc.first_vpc.id
    availability_zone = data.aws_availability_zones.available.names[1]
    cidr_block = "10.1.2.0/24"
    tags = {
    Name = "wordpress-sbnt-2"
}
}

resource "aws_internet_gateway" "gw1" {
    vpc_id = aws_vpc.first_vpc.id
    tags = {
    Name = "gw1"
  }
}

resource "aws_route_table" "rt1" {
  vpc_id = aws_vpc.first_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw1.id
  }
  tags = {
    Name = "rt1"
  }
}

resource "aws_route_table_association" "a" {
    subnet_id      = aws_subnet.sbnt-vpc1.id
    route_table_id = aws_route_table.rt1.id
}

resource "aws_route_table_association" "b" {
    subnet_id      = aws_subnet.sbnt-vpc2.id
    route_table_id = aws_route_table.rt1.id
}

### Start of EC2 block #############

data "aws_vpc" "vpc_selected" {
  id = aws_vpc.first_vpc.id
}


resource "aws_security_group" "allow_ssh_wordpress-1" {
  name        = "allow_1"
  description = "Allow ssh inbound traffic"
  vpc_id     = aws_vpc.first_vpc.id
  
  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "EFS mount target"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.vpc_selected.cidr_block]
  }

 ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_1"
  }
}

resource "aws_security_group" "db-sg" {
  name        = "db-sg"
  description = "Allow mysql inbound traffic"
  vpc_id     = aws_vpc.first_vpc.id
  
  ingress {
    description = "SSH from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_1"
  }
}


resource "aws_security_group" "allow_ssh_wordpress-2" {
  name        = "allow_2"
  description = "Allow ssh inbound traffic"
  vpc_id     = aws_vpc.first_vpc.id
  
  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "EFS mount target"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.vpc_selected.cidr_block]
  }

 ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_2"
  }
}

resource "aws_instance" "wordpress-1" {
  count = 1
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name = var.key_name
  vpc_security_group_ids = [aws_security_group.allow_ssh_wordpress-1.id]
  subnet_id   = aws_subnet.sbnt-vpc1.id
  user_data = file("install_apache.sh")
  tags = {
    Name = join("",[var.instance_name,"-wordpress-1"])
  }
}


resource "aws_instance" "wordpress-2" {
  count = 1
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name = var.key_name
  vpc_security_group_ids = [aws_security_group.allow_ssh_wordpress-2.id]
  subnet_id   = aws_subnet.sbnt-vpc2.id
  user_data = file("install_apache.sh")
  tags = {
    Name = join("",[var.instance_name,"-wordpress-2"])
  }
}

resource "aws_eip" "eip1" {
  instance = aws_instance.wordpress-1[0].id
  vpc = true
  }

resource "aws_eip" "eip2" {
  instance = aws_instance.wordpress-2[0].id
  vpc = true
  }

resource "aws_elb" "lb1" {
  name               = "LB-1"
  subnets            = [aws_subnet.sbnt-vpc1.id, aws_subnet.sbnt-vpc2.id]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }
  
  security_groups             = [aws_security_group.allow_ssh_wordpress-1.id]
  instances                   = [aws_instance.wordpress-1[0].id, aws_instance.wordpress-2[0].id]
  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags = {
    Name = "LB-1"
  }
}

output "instance_wordpress-1_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.wordpress-1[0].public_ip
}

output "instance_wordpress-2_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.wordpress-2[0].public_ip
}

