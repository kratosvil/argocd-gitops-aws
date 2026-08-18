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
REQUEST_COUNTS: dict[tuple[str, str], int] = {}  # (path, status) -> count

# Histograma de latencia, hecho a mano (mismo criterio "sin dependencias"
# del resto del proyecto) -- buckets acumulativos como exige el formato de
# Prometheus (le="X" cuenta todo <= X, no solo lo que cae justo en el rango).
LATENCY_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
REQUEST_LATENCY: dict[str, dict] = {}  # path -> {buckets: [...], sum: float, count: int}

# Metadata del pod via Downward API -- ver base/deployment.yaml. El tag de
# imagen no se expone limpio como env var sin acoplar Kustomize al build
# (el `images:` de kustomization.yaml no se propaga a runtime por si solo),
# asi que no se muestra en la pagina de estado para no mostrar un dato
# desactualizado -- `kubectl describe pod` sigue siendo la fuente real.
POD_NAME = os.getenv("POD_NAME", "unknown-pod")


# Cuenta cada request por path+status y mide latencia -- alimenta la pagina
# de estado y /metrics con el metodo RED completo (antes solo Rate, faltaban
# Errors y Duration).
@app.middleware("http")
async def count_requests(request: Request, call_next):
    path = request.url.path
    start = time.perf_counter()
    response = await call_next(request)
    duration = time.perf_counter() - start

    status = str(response.status_code)
    key = (path, status)
    REQUEST_COUNTS[key] = REQUEST_COUNTS.get(key, 0) + 1

    hist = REQUEST_LATENCY.setdefault(
        path, {"buckets": [0] * len(LATENCY_BUCKETS), "sum": 0.0, "count": 0}
    )
    for i, bound in enumerate(LATENCY_BUCKETS):
        if duration <= bound:
            hist["buckets"][i] += 1
    hist["sum"] += duration
    hist["count"] += 1

    return response


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
        "# HELP app_requests_total Requests recibidas por path y codigo de estado.",
        "# TYPE app_requests_total counter",
    ]
    for (path, status), count in REQUEST_COUNTS.items():
        lines.append(f'app_requests_total{{path="{path}",status="{status}"}} {count}')

    lines += [
        "# HELP app_request_duration_seconds Latencia de requests por path.",
        "# TYPE app_request_duration_seconds histogram",
    ]
    for path, hist in REQUEST_LATENCY.items():
        for bound, cumulative in zip(LATENCY_BUCKETS, hist["buckets"]):
            lines.append(
                f'app_request_duration_seconds_bucket{{path="{path}",le="{bound}"}} {cumulative}'
            )
        lines.append(
            f'app_request_duration_seconds_bucket{{path="{path}",le="+Inf"}} {hist["count"]}'
        )
        lines.append(f'app_request_duration_seconds_sum{{path="{path}"}} {hist["sum"]:.6f}')
        lines.append(f'app_request_duration_seconds_count{{path="{path}"}} {hist["count"]}')
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
