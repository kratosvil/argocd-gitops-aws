variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "chart_version" {
  description = "kube-prometheus-stack Helm chart version"
  type        = string
  default     = "87.17.0"
}

variable "project" {
  description = "Project tag applied to all resources"
  type        = string
  default     = "argocd-gitops-aws"
}

# SAO Platform's MCP server /incident endpoint (ALB DNS). Empty by default —
# Módulo 0 only needs to prove the webhook fires (logged by the Lambda);
# wiring this up for real incident handling is Módulo 1's job. Set it once
# SAO Platform's ECS stack is up in the same session.
variable "mcp_server_url" {
  description = "SAO Platform MCP server base URL, e.g. http://<alb-dns>. Empty = dispatcher only logs, doesn't forward."
  type        = string
  default     = ""
}

# El ALB lo crea el AWS Load Balancer Controller a partir de los recursos
# Ingress (no es un recurso de Terraform) — su DNS name puede cambiar si el
# cluster se recrea. Actualizar este valor con `kubectl get ingress -A` tras
# el Prerrequisito si difiere.
variable "alb_dns_name" {
  description = "DNS name del ALB compartido (mismo que usan argocd-server y kratosvil-replica-app)"
  type        = string
  default     = "k8s-kratosvilreplicaa-37d9f8e1dd-139128285.us-east-1.elb.amazonaws.com"
}
