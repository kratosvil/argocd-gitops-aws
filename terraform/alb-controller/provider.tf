terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "kratosvil-tfstate-805778285334"
    key            = "argocd-gitops-aws/alb-controller/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "kratosvil-tflock"
    encrypt        = true
    kms_key_id     = "alias/kratosvil-tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = "kratosvil-tfstate-805778285334"
    key    = "argocd-gitops-aws/eks/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket = "kratosvil-tfstate-805778285334"
    key    = "argocd-gitops-aws/vpc/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "iam" {
  backend = "s3"

  config = {
    bucket = "kratosvil-tfstate-805778285334"
    key    = "argocd-gitops-aws/iam/terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_ca_certificate)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}
