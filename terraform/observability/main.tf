resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"

    labels = {
      project = var.project
    }
  }
}

# kube-prometheus-stack: Prometheus + Grafana + Alertmanager + kube-state-metrics
# + node-exporter, todo en un solo chart. Sin persistencia (PVC/EBS CSI driver
# no está instalado en este cluster) — coherente con el resto del lab: efímero,
# se destruye entre sesiones, no necesita sobrevivir un reinicio de pod.
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_version
  namespace  = kubernetes_namespace.observability.metadata[0].name

  # EKS no expone controller-manager/scheduler/etcd como pods scrapeables —
  # estos ServiceMonitors siempre fallarían y no aportan nada acá.
  set {
    name  = "kubeControllerManager.enabled"
    value = "false"
  }
  set {
    name  = "kubeScheduler.enabled"
    value = "false"
  }
  set {
    name  = "kubeEtcd.enabled"
    value = "false"
  }
  set {
    name  = "kubeProxy.enabled"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "6h"
  }
  set {
    name  = "grafana.persistence.enabled"
    value = "false"
  }
  set {
    name  = "grafana.defaultDashboardsEnabled"
    value = "true"
  }

  # Receiver del Alertmanager: reenvía todo lo que entra en estado firing al
  # Lambda dispatcher vía API Gateway. group_wait/interval bajos porque esto
  # es un lab de demo, no un entorno con volumen real de alertas.
  values = [
    yamlencode({
      # Subpaths en el ALB compartido (mismo que /argocd) — cada servicio
      # necesita saber su propio prefijo para que los links/assets internos
      # no se rompan quedando expuesto detrás de un path en vez de un host.
      grafana = {
        "grafana.ini" = {
          server = {
            domain              = var.alb_dns_name
            root_url            = "%(protocol)s://%(domain)s/grafana/"
            serve_from_sub_path = true
          }
        }
      }
      prometheus = {
        prometheusSpec = {
          routePrefix = "/prometheus"
          externalUrl = "http://${var.alb_dns_name}/prometheus"
        }
      }
      alertmanager = {
        alertmanagerSpec = {
          routePrefix = "/alertmanager"
          externalUrl = "http://${var.alb_dns_name}/alertmanager"
        }
        config = {
          global = {}
          route = {
            receiver        = "webhook-dispatcher"
            group_by        = ["alertname", "namespace"]
            group_wait      = "10s"
            group_interval  = "30s"
            repeat_interval = "1h"
            # El chart trae por defecto una sub-ruta para silenciar Watchdog
            # que apunta a un receiver "null" — como reemplazamos la lista
            # de receivers completa, esa sub-ruta quedaría huérfana si no
            # se limpia explícitamente acá.
            routes = []
          }
          receivers = [
            {
              name = "webhook-dispatcher"
              webhook_configs = [
                {
                  url           = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/alertmanager-webhook"
                  send_resolved = true
                }
              ]
            }
          ]
        }
      }
    })
  ]

  timeout = 600
  wait    = true
}
