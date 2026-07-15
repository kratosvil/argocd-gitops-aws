terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "kratosvil-tfstate-805778285334"
    key            = "argocd-gitops-aws/vpc/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "kratosvil-tflock"
    encrypt        = true
    kms_key_id     = "alias/kratosvil-tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}
