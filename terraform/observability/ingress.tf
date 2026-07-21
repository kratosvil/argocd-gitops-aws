# Mismo ALB compartido que argocd-server y kratosvil-replica-app —
# group.name idéntico para que el AWS Load Balancer Controller los fusione
# en un solo Load Balancer en vez de crear uno por Ingress.
resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "kube-prometheus-stack-grafana"
    namespace = kubernetes_namespace.observability.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/group.name"      = "kratosvil-replica-app"
      "alb.ingress.kubernetes.io/group.order"     = "11"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/grafana"
          path_type = "Prefix"
          backend {
            service {
              name = "kube-prometheus-stack-grafana"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "prometheus" {
  metadata {
    name      = "kube-prometheus-stack-prometheus"
    namespace = kubernetes_namespace.observability.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"           = "alb"
      "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/group.name"  = "kratosvil-replica-app"
      "alb.ingress.kubernetes.io/group.order" = "12"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/prometheus"
          path_type = "Prefix"
          backend {
            service {
              name = "kube-prometheus-stack-prometheus"
              port {
                number = 9090
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "alertmanager" {
  metadata {
    name      = "kube-prometheus-stack-alertmanager"
    namespace = kubernetes_namespace.observability.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"           = "alb"
      "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/group.name"  = "kratosvil-replica-app"
      "alb.ingress.kubernetes.io/group.order" = "13"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/alertmanager"
          path_type = "Prefix"
          backend {
            service {
              name = "kube-prometheus-stack-alertmanager"
              port {
                number = 9093
              }
            }
          }
        }
      }
    }
  }
}
