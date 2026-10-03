terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # access_key = var.access_key # Commented out due to hardcoding, will use aws configure
  # secret_key = var.secret_key
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true # Enable DNS hostnames for instances launched in this VPC for RDS/ELB purpose
}

data "aws_availability_zones" "available" {
  state = "available" # Retrieve all available AZs in the region
}

resource "aws_subnet" "public" {
  count                   = 2 # Create two subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = ["10.0.1.0/24", "10.0.2.0/24"][count.index]              # Assign different CIDR blocks for each subnet using count.index [0] and [1]
  availability_zone       = data.aws_availability_zones.available.names[count.index] # Refer to the line 22
  map_public_ip_on_launch = true                                                     # Assign public IPs to instances launched in this subnet
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = ["10.0.11.0/24", "10.0.12.0/24"][count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id # Intenet Gateway attach
}

resource "aws_eip" "nat" {
  domain = "vpc" # Elastic IP for the NAT Gateway
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Connect the NAT Gateway in order to route to private subnets
}

# Public route table attach to the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id # Route to the Internet Gateway for public subnets
  }
}

# Private route table attach to the NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id # Route to the NAT Gateway for private subnets
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ALB faces the internet
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow inbound HTTP from the internet to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80 # HTTP port
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Anywhere
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 — only trusts the ALB and no public IP
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Allow HTTP only from the ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id] # Allow any traffic from ALB sg
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS — only trusts EC2
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow MySQL only from the EC2 security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id] # Allow any traffic from EC2 sg
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Load Balancer and Target Group

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false # This is an internet-facing ALB
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id # must be in PUBLIC subnets, across both AZs
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    healthy_threshold   = 2  # Counts of success 200 status codes before mark it healthy
    unhealthy_threshold = 2  # Counts of failed
    interval            = 30 # Every 30 seconds
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# IAM Role for EC2 to allow SSM access 

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  # To add in the assume role policy for EC2
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # Attachment of the SSM policy to the IAM role for Systems Manager access
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name # Instance profile to attach the IAM role to the EC2 instance
}

# EC2 Instances

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private[0].id # Provision in first private subnet only
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # User data script to install Apache from my AWS re/Start
  user_data = <<-EOF
    #!/bin/bash
    dnf install -y httpd wget php mariadb105-server
    wget https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-100-RESTRT-1/267-lab-NF-build-vpc-web-server/s3/lab-app.zip
    unzip lab-app.zip -d /var/www/html/
    systemctl enable httpd
    systemctl start httpd
  EOF
}

# Attach the EC2 instance to the ALB Target Group

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 80
}

# RDS Database

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id # Private subnet to connect to the EC2
}

resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-db"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "appdb"
  username = "dbadmin"
  password = var.db_password # Pass as variable in terraform.tfvars

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false
  # multi_az            = false # By default is false
  # skip_final_snapshot = true  # Skip snapshot, if delete won't keep any snapshot
}