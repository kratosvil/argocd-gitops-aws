variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "chart_version" {
  description = "argo-cd Helm chart version (chart version, not ArgoCD app version)"
  type        = string
  default     = "10.1.3"
}

variable "project" {
  description = "Project tag applied to all resources"
  type        = string
  default     = "argocd-gitops-lab"
}
