variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# SAO Platform's MCP server /incident endpoint (ALB DNS). Empty por defecto —
# el Módulo 0 solo necesita probar que el webhook dispara (queda logueado
# por el Lambda); conectarlo de verdad para manejo de incidentes es tarea
# del Módulo 1. Setear cuando el stack ECS de SAO Platform esté up en la
# misma sesión.
variable "mcp_server_url" {
  description = "SAO Platform MCP server base URL, e.g. http://<alb-dns>. Empty = dispatcher only logs, doesn't forward."
  type        = string
  default     = ""
}
