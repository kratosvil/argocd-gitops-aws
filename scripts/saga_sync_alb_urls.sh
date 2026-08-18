#!/bin/bash
# Sincroniza los valores que cambian en cada redeploy (ALB DNS + webhook URL
# de Alertmanager) en argocd/application-observability-stack.yaml.
#
# El ALB Controller crea el ALB en runtime a partir del Ingress -- no lo
# trackea Terraform, asi que su DNS cambia siempre que se destruye y se
# vuelve a levantar. Este script reemplaza el paso manual de editar el
# YAML a mano cada vez (fuente de al menos 2 bugs reales en sesiones
# anteriores: valores desincronizados que rompian Grafana/Prometheus).
#
# Correr DESPUES de: los 6 stacks de terraform/ (incluye alb-controller) +
# terraform/observability/ + al menos un Ingress ya aplicado (para que el
# ALB Controller haya asignado el hostname).
#
# Uso: bash scripts/saga_sync_alb_urls.sh [--apply]
#   Sin --apply: solo muestra el diff, no modifica nada.
#   Con --apply: escribe el archivo y hace kubectl apply.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_DIR/argocd/application-observability-stack.yaml"
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

echo "== Descubriendo ALB actual =="
ALB=$(kubectl get ingress argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -z "$ALB" ]; then
  echo "No se pudo leer el hostname del ALB (¿Ingress de argocd-server ya aplicado?)."
  exit 1
fi
echo "ALB: $ALB"

echo "== Descubriendo webhook de Alertmanager =="
WEBHOOK=$(cd "$REPO_DIR/terraform/observability" && terraform output -raw alertmanager_webhook_url 2>/dev/null)
if [ -z "$WEBHOOK" ]; then
  echo "No se pudo leer el output de terraform/observability (¿ya aplicado?)."
  exit 1
fi
echo "Webhook: $WEBHOOK"

# Valores actuales en el archivo (cualquiera de las 3 ocurrencias de dominio sirve, son iguales entre si)
CURRENT_ALB=$(grep -oP 'k8s-kratosvilreplicaa-[a-z0-9]+-[0-9]+\.us-east-1\.elb\.amazonaws\.com' "$MANIFEST" | head -1)
CURRENT_WEBHOOK=$(grep -oP 'https://[a-z0-9]+\.execute-api\.us-east-1\.amazonaws\.com/alertmanager-webhook' "$MANIFEST" | head -1)

if [ "$CURRENT_ALB" = "$ALB" ] && [ "$CURRENT_WEBHOOK" = "$WEBHOOK" ]; then
  echo ""
  echo "Ya sincronizado -- sin cambios necesarios."
  exit 0
fi

echo ""
echo "== Cambios detectados =="
[ "$CURRENT_ALB" != "$ALB" ] && echo "ALB:     $CURRENT_ALB -> $ALB"
[ "$CURRENT_WEBHOOK" != "$WEBHOOK" ] && echo "Webhook: $CURRENT_WEBHOOK -> $WEBHOOK"

if [ "$APPLY" = false ]; then
  echo ""
  echo "Dry-run (no se modifico nada). Volver a correr con --apply para escribir y aplicar."
  exit 0
fi

sed -i \
  -e "s#$CURRENT_ALB#$ALB#g" \
  -e "s#$CURRENT_WEBHOOK#$WEBHOOK#g" \
  "$MANIFEST"

echo ""
echo "== Archivo actualizado, aplicando al cluster =="
kubectl apply -f "$MANIFEST"

echo ""
echo "Listo. Recordatorio: el cambio queda en el working tree -- commitear y pushear a mano si corresponde."
