
#########################
# Retrieve Networking Outputs
#########################
data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = "wiz_terraform_state_carlos"
    key    = "networking/terraform.tfstate"
    region = "us-east-2"
  }
}

#########################
# MongoDB Credentials Variables
#########################
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

#########################
# IAM Role, Policy, and Instance Profile for EC2
#########################
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

#########################
# Security Group Allowing SSH Access
#########################
resource "aws_security_group" "mongo_sg" {
  name        = "wiz-mongo-sg"
  description = "Allow SSH access to MongoDB instance"
  vpc_id      = data.terraform_remote_state.networking.outputs.wiz_vpc_id

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

#########################
# EC2 Instance for MongoDB
#########################
resource "aws_instance" "mongo" {
  ami                    = "ami-0b6ec4b5fdedb0e2e"  # Ubuntu 16.04
  instance_type          = "t2.micro"
  subnet_id              = element(data.terraform_remote_state.networking.outputs.wiz_public_subnets, 0)
  vpc_security_group_ids = [aws_security_group.mongo_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.mongo_ec2_instance_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    # Update package list
    apt-get update -y
    # Install prerequisites
    apt-get install -y gnupg wget
    # Import MongoDB GPG key
    wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | apt-key add -
    # Add MongoDB repository for Ubuntu 16.04 (xenial)
    echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu xenial/mongodb-org/4.4 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-4.4.list
    # Update and install MongoDB
    apt-get update -y && apt-get install -y mongodb-org
    # Start MongoDB
    systemctl start mongod
    systemctl enable mongod
    sleep 10
    # Create admin user using provided credentials
    mongo --eval 'db.getSiblingDB("admin").createUser({user:"${var.mongo_admin_user}", pwd:"${var.mongo_admin_password}", roles:[{role:"userAdminAnyDatabase", db:"admin"}]})'
    # Enable authentication in MongoDB configuration
    sed -i '/#security:/a\  authorization: enabled' /etc/mongod.conf
    # Restart MongoDB to apply changes
    systemctl restart mongod
  EOF

  tags = {
    Name = "wiz-mongo-instance"
  }
}
