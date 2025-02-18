terraform {
  backend "s3" {
    bucket = "wiz-terraform-state-carlosf"
    key    = "infrastructure/terraform.tfstate"
    region = "ap-southeast-2"
  }
}

provider "aws" {
  region = var.aws_region
}

##############################
# VARIABLES
##############################
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-southeast-2"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnets_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_subnets_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.1.101.0/24", "10.1.102.0/24"]
}

# MongoDB credentials (pass these as TF_VAR_mongo_admin_user and TF_VAR_mongo_admin_password)
variable "mongo_admin_user" {
  description = "MongoDB admin username"
  type        = string
  sensitive   = true
}

variable "mongo_admin_password" {
  description = "MongoDB admin password"
  type        = string
  sensitive   = true
}

##############################
# NETWORKING RESOURCES
##############################

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Create the VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "wiz-vpc"
  }
}

# Create the Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "wiz-igw"
  }
}

# Create public subnets
resource "aws_subnet" "public" {
  count                   = length(var.public_subnets_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "wiz-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Create private subnets
resource "aws_subnet" "private" {
  count             = length(var.private_subnets_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "wiz-private-${count.index + 1}"
  }
}

# Allocate an Elastic IP for the NAT Gateway (use domain attribute instead of vpc)
resource "aws_eip" "nat" {
  domain = "vpc"
}

# Create the NAT Gateway in the first public subnet
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "wiz-nat"
  }
  depends_on = [aws_internet_gateway.igw]
}

# Create a public route table with a route to the IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "wiz-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Create a private route table with a route to the NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "wiz-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

##############################
# MONGODB SERVER RESOURCES
##############################

# Create an IAM role for the EC2 instance
resource "aws_iam_role" "mongo_ec2_role" {
  name = "wiz-mongo-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mongo_ec2_role_attach" {
  role       = aws_iam_role.mongo_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "mongo_ec2_instance_profile" {
  name = "wiz-mongo-ec2-profile"
  role = aws_iam_role.mongo_ec2_role.name
}

# Create a Security Group allowing SSH access for the MongoDB EC2 instance
resource "aws_security_group" "mongo_sg" {
  name        = "wiz-mongo-sg"
  description = "Allow SSH access to MongoDB instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
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
    Name = "wiz-mongo-sg"
  }
}

# Create the EC2 instance for MongoDB
resource "aws_instance" "mongo" {
  ami                    = "ami-0b87a8055f0211d32"  # Ubuntu 16.04
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public[0].id  # Use the first public subnet
  vpc_security_group_ids = [aws_security_group.mongo_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.mongo_ec2_instance_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y gnupg wget
    wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | apt-key add -
    echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/4.4 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-4.4.list
    apt-get update -y && apt-get install -y mongodb-org
    systemctl start mongod
    systemctl enable mongod
    sleep 10
    mongo --eval 'db.getSiblingDB("admin").createUser({user:"${var.mongo_admin_user}", pwd:"${var.mongo_admin_password}", roles:[{role:"userAdminAnyDatabase", db:"admin"}]})'
    sed -i '/#security:/a\  authorization: enabled' /etc/mongod.conf
    systemctl restart mongod
  EOF

  tags = {
    Name = "wiz-mongo-instance"
  }
}

##############################
# OUTPUTS
##############################
output "wiz_vpc_id" {
  value = aws_vpc.main.id
}

output "wiz_public_subnets" {
  value = aws_subnet.public[*].id
}

output "wiz_private_subnets" {
  value = aws_subnet.private[*].id
}

output "wiz_nat_gateway_id" {
  value = aws_nat_gateway.nat.id
}
