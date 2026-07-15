variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name — used in subnet discovery tags"
  type        = string
  default     = "argocd-gitops-aws"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, one per AZ"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "availability_zones" {
  description = "AZs to spread the public subnets across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "project" {
  description = "Project tag applied to all resources"
  type        = string
  default     = "argocd-gitops-aws"
}
