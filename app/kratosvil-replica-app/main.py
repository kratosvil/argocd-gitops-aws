"""
kratosvil-replica-app — microservicio de ejemplo para el demo de SAGA.
Reemplaza la pagina estatica de nginx: FastAPI real, con /health y /metrics
en formato Prometheus, para que Grafana muestre metricas de aplicacion
reales (no solo de infraestructura) durante el video del Modulo 11.
"""
import os
import time
from collections import deque

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

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

# Historial acotado (timestamp, duracion) para las sparklines en vivo de "/"
# -- deque con maxlen, memoria fija sin importar cuanto trafico reciba.
RECENT_EVENTS: deque[tuple[float, float]] = deque(maxlen=2000)
SPARKLINE_WINDOW_S = 30

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

    RECENT_EVENTS.append((time.time(), duration))

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


@app.get("/stats")
def stats():
    """JSON pensado para el polling del front-end de '/' -- separa la
    presentacion (HTML/JS) de los numeros, sin parsear el formato texto
    de /metrics en el navegador. Bucketiza RECENT_EVENTS en ventanas de
    1s para las dos sparklines (requests/s y latencia promedio)."""
    now = time.time()
    buckets = [0] * SPARKLINE_WINDOW_S
    latency_sum = [0.0] * SPARKLINE_WINDOW_S
    for ts, duration in RECENT_EVENTS:
        age = now - ts
        if age < 0 or age >= SPARKLINE_WINDOW_S:
            continue
        idx = SPARKLINE_WINDOW_S - 1 - int(age)
        buckets[idx] += 1
        latency_sum[idx] += duration

    latency_ms = [
        round((latency_sum[i] / buckets[i]) * 1000, 2) if buckets[i] else 0
        for i in range(SPARKLINE_WINDOW_S)
    ]

    return JSONResponse({
        "pod": POD_NAME,
        "uptime_seconds": round(now - START_TIME),
        "total_requests": sum(REQUEST_COUNTS.values()),
        "requests_per_sec": buckets,
        "latency_ms": latency_ms,
    })


@app.get("/", response_class=HTMLResponse)
def status_page():
    uptime = time.time() - START_TIME
    total_requests = sum(REQUEST_COUNTS.values())
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>kratosvil-replica-app</title>
<style>
  body {{
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    background: #0d1117; color: #c9d1d9;
    max-width: 640px; margin: 64px auto; padding: 0 20px;
  }}
  .card {{ border: 1px solid #21262d; border-radius: 12px; padding: 28px 32px; background: #161b22; }}
  .head {{ display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; }}
  h1 {{ font-size: 16px; font-weight: 600; margin: 0; color: #e6edf3; }}
  .live {{ font-size: 12px; color: #3fb950; display: flex; align-items: center; gap: 6px; }}
  .dot {{ width: 8px; height: 8px; border-radius: 50%; background: #3fb950; animation: pulse 1.6s infinite; }}
  @keyframes pulse {{ 0%,100% {{ opacity: 1; }} 50% {{ opacity: 0.35; }} }}
  .metric {{ margin-bottom: 18px; }}
  .metric .label {{ font-size: 11px; color: #7d8590; text-transform: uppercase; letter-spacing: 0.04em; margin-bottom: 6px; }}
  .metric svg {{ width: 100%; height: 40px; display: block; }}
  .footer {{ display: flex; justify-content: space-between; margin-top: 20px; padding-top: 16px; border-top: 1px solid #21262d; font-size: 12px; color: #7d8590; }}
  .footer b {{ color: #c9d1d9; }}
</style></head>
<body>
  <div class="card">
    <div class="head">
      <h1>kratosvil-replica-app</h1>
      <span class="live"><span class="dot"></span>live</span>
    </div>

    <div class="metric">
      <div class="label">requests / s</div>
      <svg viewBox="0 0 300 40" preserveAspectRatio="none">
        <polyline id="rps-spark" fill="none" stroke="#3fb950" stroke-width="2" points=""></polyline>
      </svg>
    </div>
    <div class="metric">
      <div class="label">latencia promedio (ms)</div>
      <svg viewBox="0 0 300 40" preserveAspectRatio="none">
        <polyline id="lat-spark" fill="none" stroke="#58a6ff" stroke-width="2" points=""></polyline>
      </svg>
    </div>

    <div class="footer">
      <span>total <b id="total">{total_requests}</b></span>
      <span>uptime <b id="uptime">{uptime:.0f}s</b></span>
      <span>pod <b id="pod">{POD_NAME}</b></span>
    </div>
  </div>

<script>
function drawSparkline(id, data) {{
  const max = Math.max(...data, 1);
  const w = 300, h = 40;
  const step = data.length > 1 ? w / (data.length - 1) : w;
  const points = data.map((v, i) => (i * step).toFixed(1) + "," + (h - (v / max) * (h - 4) - 2).toFixed(1)).join(" ");
  document.getElementById(id).setAttribute("points", points);
}}

function fmtUptime(s) {{
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return String(h).padStart(2, "0") + ":" + String(m).padStart(2, "0") + ":" + String(sec).padStart(2, "0");
}}

async function refresh() {{
  try {{
    const res = await fetch("/stats");
    const d = await res.json();
    document.getElementById("total").textContent = d.total_requests.toLocaleString();
    document.getElementById("uptime").textContent = fmtUptime(d.uptime_seconds);
    document.getElementById("pod").textContent = d.pod;
    drawSparkline("rps-spark", d.requests_per_sec);
    drawSparkline("lat-spark", d.latency_ms);
  }} catch (e) {{ /* pagina sigue mostrando el ultimo valor conocido */ }}
}}

refresh();
setInterval(refresh, 2000);
</script>
</body></html>"""
