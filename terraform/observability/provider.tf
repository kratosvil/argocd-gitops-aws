terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "kratosvil-tfstate-805778285334"
    key            = "argocd-gitops-aws/observability/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "kratosvil-tflock"
    encrypt        = true
    kms_key_id     = "alias/kratosvil-tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
