# El chart kube-prometheus-stack y sus Ingress viven en ArgoCD
# (argocd/application-observability-stack.yaml + observability/manifests/),
# no en Terraform — a diferencia de ArgoCD mismo o el ALB Controller, este
# chart no tiene dependencia de arranque, así que le corresponde el
# self-healing real de ArgoCD en vez de quedar atado a un terraform apply
# manual. Este stack de Terraform ahora solo tiene lo que es AWS puro sin
# ángulo de Kubernetes: Lambda dispatcher + IAM + API Gateway (ver lambda.tf
# y apigateway.tf).
