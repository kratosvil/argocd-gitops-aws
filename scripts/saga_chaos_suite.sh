#!/bin/bash
# Suite de fallos a proposito para SAGA -- rompe overlays/dev con causas raiz
# REALES y distintas (no la misma imagen busybox repetida) y verifica que el
# agente se auto-gestione de punta a punta: detecta -> decide -> propone ->
# ejecuta via PR -> CI -> merge -> ArgoCD sincroniza -> pod sano de nuevo.
#
# Cada escenario termina en CrashLoopBackOff real (la unica condicion que
# dispara SagaPodCrashLooping), pero por una causa distinta:
#   1. crash-immediate  -- el proceso muere al arrancar (exit 1)
#   2. hang-no-health   -- el proceso queda vivo pero nunca sirve /health,
#                          la liveness probe lo mata en loop
#   3. oom-kill         -- el proceso crece en memoria hasta pasar el limit
#                          (64Mi) y el kernel lo mata (OOMKilled)
#
# Secuencial a proposito -- no dispara el siguiente hasta que el anterior se
# autocurco (evita apilar el bug de dedup ya conocido con incidentes
# superpuestos). Cuesta Bedrock real (~$0.01-0.02 por escenario). No
# modifica nada si un escenario no se autocura dentro del timeout -- corta
# ahi y avisa para intervencion manual.
#
# Uso: bash scripts/saga_chaos_suite.sh
set -uo pipefail

ECR="805778285334.dkr.ecr.us-east-1.amazonaws.com/kratosvil-replica-app"
GITOPS_DIR="$HOME/Desarrollo/projects/saga-gitops-manifests"
KUSTOM="$GITOPS_DIR/overlays/dev/kustomization.yaml"
NS="kratosvil-replica-app-dev"
DEPLOY="kratosvil-replica-app"
HEAL_TIMEOUT=300   # 5min -- tiempo maximo para que el ciclo completo cierre
POLL_INTERVAL=10
# Tag bueno de referencia FIJO, no derivado de "lo que este corriendo ahora".
# Bug real encontrado 2026-08-13: al usar SAGA_CHAOS_ONLY para re-correr
# escenarios sueltos, un escenario anterior podia seguir roto -- capturar
# good_tag desde el deploy en vivo heredaba esa rotura como "tag bueno",
# haciendo que un self-heal real (a fastapi-v1) se reportara como FAIL.
GOOD_TAG="fastapi-v1"

RESULTS=()

current_image_tag() {
  kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | awk -F: '{print $NF}'
}

deploy_ready() {
  local ready total
  ready=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  total=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  [ -n "$ready" ] && [ "$ready" = "$total" ]
}

build_image() {
  # $1 = tag, $2 = comando (vacio = imagen tal cual, sin override)
  local tag="$1" cmd="$2"
  if [ -z "$cmd" ]; then
    docker pull -q busybox:stable >/dev/null
    docker tag busybox:stable "$ECR:$tag"
  else
    docker rm -f saga_chaos_tmp >/dev/null 2>&1
    docker pull -q busybox:stable >/dev/null
    docker create --name saga_chaos_tmp busybox:stable sh -c "$cmd" >/dev/null
    docker commit saga_chaos_tmp "$ECR:$tag" >/dev/null
    docker rm -f saga_chaos_tmp >/dev/null
  fi
  docker push -q "$ECR:$tag" >/dev/null
}

run_scenario() {
  local name="$1" cmd="$2"
  local ts tag good_tag start_t elapsed healed=0

  ts=$(date +%s)
  tag="chaos-${name}-${ts}"
  good_tag="$GOOD_TAG"

  echo ""
  echo "===== Escenario: $name ====="
  echo "Tag bueno de referencia: $good_tag"
  echo "Imagen rota: $tag"

  # Precondicion: no arrancar un escenario nuevo si el deploy no esta sano
  # todavia (evita apilar roturas si algo anterior no cerro solo).
  echo "Verificando que el deploy este sano antes de arrancar (timeout 60s)..."
  pre_ok=0
  pre_start=$(date +%s)
  while [ $(( $(date +%s) - pre_start )) -lt 60 ]; do
    if [ "$(current_image_tag)" = "$good_tag" ] && deploy_ready; then pre_ok=1; break; fi
    sleep 5
  done
  if [ "$pre_ok" = "0" ]; then
    echo "FAIL - el deploy no esta sano en $good_tag antes de empezar (tag actual: $(current_image_tag)) -- no arranco este escenario"
    RESULTS+=("FAIL $name not-healthy-precondition")
    return
  fi

  build_image "$tag" "$cmd"

  # Sincronizar SIEMPRE con origin/main antes de editar -- el poller de SAGA
  # puede haber mergeado un revert de un escenario anterior mientras este
  # arrancaba, y un push sobre un HEAD local viejo se rechaza (non-fast-
  # forward). Bug real encontrado 2026-08-13: sin esto, dos escenarios
  # seguidos dieron un PASS falso en 15s porque el push fallo en silencio,
  # el commit roto nunca llego a main, y el pod nunca se rompio de verdad.
  ( cd "$GITOPS_DIR" && git fetch -q origin main && git reset --hard -q origin/main )

  sed -i "s/newTag: .*/newTag: $tag/" "$KUSTOM"
  if ! ( cd "$GITOPS_DIR" && git add overlays/dev/kustomization.yaml && \
         git commit -q -m "chaos: escenario '$name' -- exploracion automatizada SAGA ($ts)" && \
         git push -q ); then
    echo "FAIL - git push rechazado, el commit roto nunca llego a main (no se disparo nada)"
    RESULTS+=("FAIL $name push-rejected")
    return
  fi

  kubectl -n argocd patch application kratosvil-replica-app-dev --type merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1

  # Confirmar que el incidente se disparo de verdad (el tag desplegado
  # realmente paso a ser el roto) antes de esperar a que se cure -- si nunca
  # se rompe, "curado" seria un falso positivo trivial.
  echo "Confirmando que el incidente se disparo (timeout 90s)..."
  broke=0
  brk_start=$(date +%s)
  while [ $(( $(date +%s) - brk_start )) -lt 90 ]; do
    sleep 5
    if [ "$(current_image_tag)" = "$tag" ]; then
      broke=1
      break
    fi
  done
  if [ "$broke" = "0" ]; then
    echo "FAIL - ArgoCD nunca desplego la imagen rota dentro de 90s (revisar sync)"
    RESULTS+=("FAIL $name never-deployed")
    return
  fi
  echo "Incidente confirmado -- pod corriendo $tag"

  echo "Esperando a que se autocure (timeout ${HEAL_TIMEOUT}s)..."
  start_t=$(date +%s)
  while [ $(( $(date +%s) - start_t )) -lt "$HEAL_TIMEOUT" ]; do
    sleep "$POLL_INTERVAL"
    now_tag=$(current_image_tag)
    if [ "$now_tag" = "$good_tag" ] && deploy_ready; then
      healed=1
      break
    fi
  done
  elapsed=$(( $(date +%s) - start_t ))

  if [ "$healed" = "1" ]; then
    echo "PASS - autocurado en ${elapsed}s (volvio a $good_tag, deployment Ready)"
    RESULTS+=("PASS $name ${elapsed}s")
  else
    echo "FAIL - no se autocuro dentro de ${HEAL_TIMEOUT}s (tag actual: $(current_image_tag))"
    echo "       Revisar manualmente -- kubectl get pods -n $NS / gh pr list --repo kratosvil/saga-gitops-manifests"
    RESULTS+=("FAIL $name ${elapsed}s")
  fi
}

last_passed() {
  [ "${#RESULTS[@]}" -eq 0 ] && return 0
  [[ "${RESULTS[$((${#RESULTS[@]}-1))]}" == PASS* ]]
}

# SAGA_CHAOS_ONLY="hang-no-health oom-kill" bash scripts/saga_chaos_suite.sh
# corre solo esos escenarios (util para re-correr los que fallaron sin
# repetir los que ya se validaron). Sin definir, corre los 3 en orden.
main() {
  echo "SAGA -- suite de fallos a proposito (3 causas raiz distintas)"
  echo "Costo estimado: ~\$0.01-0.02 por escenario en llamadas reales a Bedrock."

  local only="${SAGA_CHAOS_ONLY:-}"
  should_run() { [ -z "$only" ] || [[ " $only " == *" $1 "* ]]; }

  if should_run "crash-immediate"; then
    run_scenario "crash-immediate" ""
  fi

  if should_run "hang-no-health" && { [ -n "$only" ] || last_passed; }; then
    run_scenario "hang-no-health" "sleep 999999"
  fi

  if should_run "oom-kill" && { [ -n "$only" ] || last_passed; }; then
    run_scenario "oom-kill" 'x="a"; while true; do x="$x$x"; done'
  fi

  echo ""
  echo "===================================="
  echo "Resumen de la suite:"
  for r in "${RESULTS[@]}"; do echo "  $r"; done
  echo "===================================="
}

main
