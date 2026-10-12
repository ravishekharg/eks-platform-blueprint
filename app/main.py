"""A small HTTP service used to exercise the platform.

It behaves like a well-mannered production service, which is what the platform depends on:
- /health is a liveness check: the process is up. It never checks dependencies.
- /ready is a readiness check: it turns false while starting and while shutting down, so the
  pod leaves the load balancer before it stops serving.
- /metrics exposes Prometheus request counters and latency histograms.
- On SIGTERM it stops reporting ready, keeps serving in-flight requests for a drain period,
  then exits (uvicorn handles the final shutdown).
Configuration comes only from environment variables, so the same image runs in every environment.
"""
import asyncio
import os
import signal
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

SERVICE_NAME = os.environ.get("SERVICE_NAME", "sample")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "local")
VERSION = os.environ.get("VERSION", "dev")
STARTUP_DELAY_SECONDS = float(os.environ.get("STARTUP_DELAY_SECONDS", "0"))
DRAIN_SECONDS = float(os.environ.get("DRAIN_SECONDS", "5"))

REQUESTS = Counter("http_requests_total", "HTTP requests", ["service", "method", "path", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency", ["service", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)

state = {"started_at": time.monotonic(), "draining": False}


def _install_drain_handler():
    """Wrap uvicorn's SIGTERM handler: report not-ready, keep serving, then shut down.

    Kubernetes sends SIGTERM at the same time it starts removing the pod from Service endpoints
    and load balancer targets. Reporting not-ready and serving for DRAIN_SECONDS more covers the
    time that removal takes to reach every node, so no request hits a closed socket.
    """
    uvicorn_handler = signal.getsignal(signal.SIGTERM)
    if not callable(uvicorn_handler):
        return
    loop = asyncio.get_running_loop()

    def on_sigterm(signum, frame):
        if state["draining"]:
            return
        state["draining"] = True
        loop.call_later(DRAIN_SECONDS, uvicorn_handler, signum, frame)

    signal.signal(signal.SIGTERM, on_sigterm)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    _install_drain_handler()
    yield


app = FastAPI(title=SERVICE_NAME, lifespan=lifespan)


def _ready() -> bool:
    warmed_up = time.monotonic() - state["started_at"] >= STARTUP_DELAY_SECONDS
    return warmed_up and not state["draining"]


@app.middleware("http")
async def _metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # Use the route template, not the raw path, so metric labels stay low-cardinality.
    route = request.scope.get("route")
    path = getattr(route, "path", "unmatched")
    REQUESTS.labels(SERVICE_NAME, request.method, path, str(response.status_code)).inc()
    LATENCY.labels(SERVICE_NAME, path).observe(time.perf_counter() - start)
    return response


@app.get("/")
def index():
    return {"service": SERVICE_NAME, "environment": ENVIRONMENT, "version": VERSION}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    if not _ready():
        response.status_code = 503
        return {"ready": False, "draining": state["draining"]}
    return {"ready": True}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
