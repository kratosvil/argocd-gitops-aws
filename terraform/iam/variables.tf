variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project tag applied to all resources"
  type        = string
  default     = "argocd-gitops-aws"
}

variable "github_org" {
  description = "GitHub organization/user that owns the repo"
  type        = string
  default     = "kratosvil"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "argocd-gitops-aws"
}
