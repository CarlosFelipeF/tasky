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
  count                   = length(var.private_subnets_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnets_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
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
# EKS CLUSTER & NODE GROUP RESOURCES
##############################
# Create an IAM Role for the EKS cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "eks.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Create the EKS Cluster using version 1.32.
resource "aws_eks_cluster" "eks_cluster" {
  name     = "my-eks-cluster"
  version  = "1.32"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [aws_internet_gateway.igw]
}

# Create an IAM Role for the EKS node group.
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ec2_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Create an EKS Managed Node Group in your private subnets.
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "eks-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  instance_types = ["t3.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ec2_policy,
  ]
}

##############################
# AWS LOAD BALANCER CONTROLLER DEPLOYMENT
##############################

# Data sources to get EKS cluster info for Helm
data "aws_eks_cluster" "cluster" {
  name = aws_eks_cluster.eks_cluster.name
}

data "aws_eks_cluster_auth" "cluster" {
  name = aws_eks_cluster.eks_cluster.name
}

# Get the OIDC provider (required for associating IAM roles with service accounts)
data "aws_iam_openid_connect_provider" "eks_oidc" {
  url = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}

# Create an IAM Role for the AWS LB Controller with OIDC trust
resource "aws_iam_role" "alb_controller_role" {
  name = "eks-alb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.eks_oidc.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        "StringEquals" = {
          "${replace(data.aws_iam_openid_connect_provider.eks_oidc.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

# Attach the recommended LB Controller policy (replace the policy ARN with the current AWS recommended ARN)
resource "aws_iam_role_policy_attachment" "alb_controller_policy_attach" {
  role       = aws_iam_role.alb_controller_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLoadBalancerControllerIAMPolicy"
}

# Create the Kubernetes service account for the LB Controller
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  token                  = data.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
}

resource "kubernetes_service_account" "alb_controller_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller_role.arn
    }
  }
}

# Configure the Helm provider to deploy the LB Controller
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    token                  = data.aws_eks_cluster_auth.cluster.token
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  }
}

# Deploy the AWS Load Balancer Controller via Helm
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  chart      = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  namespace  = "kube-system"
  version    = "1.5.3"  # Adjust the version if needed

  set {
    name  = "clusterName"
    value = aws_eks_cluster.eks_cluster.name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller_sa.metadata[0].name
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

# New Outputs for EKS
output "eks_cluster_name" {
  value = aws_eks_cluster.eks_cluster.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.eks_cluster.endpoint
}
