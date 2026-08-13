#!/bin/bash
# Checklist funcional repetible de SAGA (SV-AOP-012).
#
# Correr despues de cada redeploy y antes de grabar/demostrar -- no modifica
# nada, solo lee/verifica contra la infra real. Requiere: kubectl (contexto
# del cluster SAGA), aws cli, curl, terraform, gh (opcional, para PRs
# abiertos). Termina en exit 0 si no hubo FAIL, exit 1 si hubo alguno.
#
# Uso: bash scripts/saga_functional_check.sh
set -uo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "OK   - $1"; PASS=$((PASS+1)); }
warn() { echo "WARN - $1"; WARN=$((WARN+1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

SAO_TF_DIR="$(cd "$(dirname "$0")/../../sao-platform/terraform" 2>/dev/null && pwd || echo "$HOME/Desarrollo/projects/sao-platform/terraform")"

# Los 5 Ingress del cluster comparten un solo ALB (mismo grupo) -- cualquiera
# sirve para descubrir el hostname.
ALB="${SAGA_ALB:-$(kubectl get ingress -A -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)}"
echo "ALB detectado: ${ALB:-<no encontrado -- cluster arriba?>}"
echo ""

echo "== 1. Infra base =="
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc " Ready ")
[ "$NOT_READY" = "0" ] && ok "nodos EKS todos Ready" || fail "$NOT_READY nodo(s) EKS no Ready"

BAD_PODS=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l)
[ "$BAD_PODS" = "0" ] && ok "sin pods fuera de Running/Succeeded" || warn "$BAD_PODS pod(s) fuera de Running/Succeeded"

kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null |
while read -r name sync health; do
  [ -z "$name" ] && continue
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    echo "OK   - ArgoCD $name: $sync/$health"
  else
    echo "WARN - ArgoCD $name: $sync/$health (revisar si es esperado -- ej. prod fuera de alcance del demo)"
  fi
done

echo ""
echo "== 2. Observabilidad =="
DOWN_TARGETS=$(curl -s --max-time 10 "http://$ALB/prometheus/api/v1/targets" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(len([t for t in d['data']['activeTargets'] if t['health']!='up']))
except Exception:
    print('ERR')
" 2>/dev/null)
[ "$DOWN_TARGETS" = "0" ] && ok "todos los targets de Prometheus up" || fail "Prometheus: $DOWN_TARGETS target(s) caidos o sin responder"

for path in grafana/login alertmanager/; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB/$path")
  [ "$CODE" = "200" ] && ok "/$path responde 200" || fail "/$path responde $CODE"
done

WATCHDOG_RECV=$(curl -s --max-time 10 "http://$ALB/alertmanager/api/v2/alerts" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for a in d:
        if a['labels'].get('alertname')=='Watchdog':
            print(','.join(r['name'] for r in a.get('receivers',[])))
            break
    else:
        print('no-encontrado')
except Exception:
    print('ERR')
" 2>/dev/null)
[ "$WATCHDOG_RECV" = "null" ] && ok "Watchdog ruteado a receiver null (no gasta Bedrock)" || warn "Watchdog ruteado a: $WATCHDOG_RECV (esperado: null)"

echo ""
echo "== 3. App demo =="
for path in "" health metrics; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB/$path")
  [ "$CODE" = "200" ] && ok "/$path responde 200" || fail "/$path responde $CODE"
done

echo ""
echo "== 4. IAM -- Modulo 2 (razonador sin escritura directa) =="
DANGEROUS=$(aws iam get-role-policy --role-name sao-platform-ecs-task --policy-name sao-mcp-server-policy 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
actions=[]
for s in d['PolicyDocument']['Statement']:
    a=s.get('Action')
    if isinstance(a,str): a=[a]
    actions += a or []
bad=[a for a in actions if any(a.lower().startswith(p) for p in ('ecs:update','lambda:update','rds:reboot'))]
print(len(bad))
" 2>/dev/null)
[ "$DANGEROUS" = "0" ] && ok "rol del razonador sin acciones de escritura peligrosas" || fail "se encontraron $DANGEROUS accion(es) de escritura peligrosas en el rol del razonador"

echo ""
echo "== 5. Consola HITL -- Modulo 10/10b/10c =="
cd "$SAO_TF_DIR" || { fail "no encuentro sao-platform/terraform en $SAO_TF_DIR"; }
HITL_URL=$(terraform output -raw hitl_api_url 2>/dev/null)
TOKEN=$(terraform output -raw hitl_console_token 2>/dev/null)

CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HITL_URL/hitl/pending")
[ "$CODE" = "302" ] && ok "/hitl/pending sin sesion redirige a login (fail-closed)" || fail "/hitl/pending sin sesion devuelve $CODE (esperado 302)"

CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HITL_URL/hitl/pending" -H "Authorization: Bearer $TOKEN")
[ "$CODE" = "200" ] && ok "/hitl/pending con Bearer token responde 200" || fail "/hitl/pending con Bearer token devuelve $CODE"

JAR=$(mktemp)
curl -s -c "$JAR" --max-time 10 -X POST "$HITL_URL/hitl/login" --data-urlencode "token=$TOKEN" -o /dev/null
CODE=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" --max-time 10 "$HITL_URL/hitl/history")
[ "$CODE" = "200" ] && ok "login por cookie + /hitl/history responde 200" || fail "/hitl/history con cookie devuelve $CODE"
rm -f "$JAR"

echo ""
echo "== 6. Guardrails / PRs abiertos (informativo, no es fail) =="
gh pr list --repo kratosvil/saga-gitops-manifests --state open --json number,title 2>/dev/null | python3 -c "
import sys,json
prs=json.load(sys.stdin)
if prs:
    print(f'INFO - {len(prs)} PR(s) abiertos pendientes de decision humana:')
    for p in prs: print(f\"       #{p['number']} {p['title']}\")
else:
    print('OK   - sin PRs abiertos')
"

echo ""
echo "===================================="
echo "Resumen: $PASS OK / $WARN WARN / $FAIL FAIL"
echo "===================================="
[ "$FAIL" -eq 0 ]
