"""
kratosvil-replica-app — microservicio de ejemplo para el demo de SAGA.
Reemplaza la pagina estatica de nginx: FastAPI real, con /health y /metrics
en formato Prometheus, para que Grafana muestre metricas de aplicacion
reales (no solo de infraestructura) durante el video del Modulo 11.
"""
import os
import time

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, PlainTextResponse

app = FastAPI(title="kratosvil-replica-app")

# Estado en memoria del proceso -- se resetea en cada restart/deploy a
# proposito, es un demo, no necesita persistencia.
START_TIME = time.time()
REQUEST_COUNTS: dict[str, int] = {}

# Metadata del pod via Downward API -- ver base/deployment.yaml. El tag de
# imagen no se expone limpio como env var sin acoplar Kustomize al build
# (el `images:` de kustomization.yaml no se propaga a runtime por si solo),
# asi que no se muestra en la pagina de estado para no mostrar un dato
# desactualizado -- `kubectl describe pod` sigue siendo la fuente real.
POD_NAME = os.getenv("POD_NAME", "unknown-pod")


# Cuenta cada request por path -- alimenta tanto la pagina de estado como
# /metrics, asi Grafana tiene algo real que graficar sin necesitar un
# generador de carga aparte.
@app.middleware("http")
async def count_requests(request: Request, call_next):
    path = request.url.path
    REQUEST_COUNTS[path] = REQUEST_COUNTS.get(path, 0) + 1
    return await call_next(request)


@app.get("/health")
def health():
    return {"status": "ok", "pod": POD_NAME}


@app.get("/metrics", response_class=PlainTextResponse)
def metrics():
    """Formato texto de Prometheus a mano -- sin libreria extra, mismo
    criterio 'sin dependencias' del resto del proyecto (ver _extract_tag en
    lambda-hitl/handler.py)."""
    uptime = time.time() - START_TIME
    lines = [
        "# HELP app_uptime_seconds Tiempo desde que arranco el proceso.",
        "# TYPE app_uptime_seconds gauge",
        f"app_uptime_seconds {uptime:.2f}",
        "# HELP app_requests_total Requests recibidas por path.",
        "# TYPE app_requests_total counter",
    ]
    for path, count in REQUEST_COUNTS.items():
        lines.append(f'app_requests_total{{path="{path}"}} {count}')
    return "\n".join(lines) + "\n"


@app.get("/", response_class=HTMLResponse)
def status_page():
    uptime = time.time() - START_TIME
    total_requests = sum(REQUEST_COUNTS.values())
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>kratosvil-replica-app</title>
<style>
  body {{ font-family: -apple-system, sans-serif; max-width: 640px; margin: 64px auto; padding: 0 20px; color: #16211d; }}
  .card {{ border: 1px solid #c7d0c9; border-radius: 8px; padding: 24px 28px; }}
  h1 {{ font-size: 22px; margin: 0 0 6px; }}
  .tag {{ font-family: ui-monospace, monospace; font-size: 12px; color: #0f6e64; background: #e4e9e5; padding: 2px 8px; border-radius: 99px; }}
  dl {{ display: grid; grid-template-columns: 140px 1fr; gap: 8px 12px; margin-top: 20px; font-size: 14px; }}
  dt {{ color: #74807a; font-family: ui-monospace, monospace; font-size: 11px; text-transform: uppercase; }}
  dd {{ margin: 0; font-family: ui-monospace, monospace; }}
</style></head>
<body>
  <div class="card">
    <span class="tag">healthy</span>
    <h1>kratosvil-replica-app</h1>
    <dl>
      <dt>Servido por</dt><dd>{POD_NAME}</dd>
      <dt>Uptime</dt><dd>{uptime:.0f}s</dd>
      <dt>Requests totales</dt><dd>{total_requests}</dd>
    </dl>
  </div>
</body></html>"""
