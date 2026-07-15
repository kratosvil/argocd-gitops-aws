variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "chart_version" {
  description = "aws-load-balancer-controller Helm chart version"
  type        = string
  default     = "3.4.2"
}
