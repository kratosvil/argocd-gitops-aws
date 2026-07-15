resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"

    labels = {
      project = var.project
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Single t3.small node — non-HA is the right shape for this lab, HA mode
  # would try to spread redundant replicas we have no capacity for.
  set {
    name  = "redis-ha.enabled"
    value = "false"
  }

  set {
    name  = "controller.replicas"
    value = "1"
  }

  # Serve under /argocd on the shared ALB: no TLS at this backend (the ALB
  # itself has no TLS either in this iteration — no owned domain for ACM),
  # and the ALB Ingress Controller doesn't rewrite paths, so ArgoCD needs to
  # know its own subpath to render correct asset/API URLs.
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  set {
    name  = "configs.params.server\\.basehref"
    value = "/argocd"
  }

  set {
    name  = "configs.params.server\\.rootpath"
    value = "/argocd"
  }

  timeout = 300
  wait    = true
}
