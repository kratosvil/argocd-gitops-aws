variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "repository_name" {
  description = "ECR repository name"
  type        = string
  default     = "kratosvil-replica-app"
}

variable "project" {
  description = "Project tag applied to all resources"
  type        = string
  default     = "argocd-gitops-aws"
}
