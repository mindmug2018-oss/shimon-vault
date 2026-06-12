"""
main.py — ShimonVault FastAPI entry point

STARTUP DESIGN:
  The /health endpoint MUST return HTTP 200 immediately so the ALB health
  check passes and the instance is marked healthy.  DB initialisation is
  therefore moved to a background thread that retries until RDS is ready
  (takes 30-60 s after the EC2 boots).  The app serves traffic while the
  DB is still warming up; any route that actually hits the DB will get a
  503 until init_db() succeeds, but the health check stays green.
"""

import logging
import threading
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from config import APP_VERSION, PROJECT_NAME, ENVIRONMENT
from database import init_db, check_db_connection

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
)
logger = logging.getLogger(__name__)

# ── DB-init state (read by /health) ──────────────────────────────────────────
_db_ready = False
_db_init_error: str = ""


def _init_db_with_retry(max_attempts: int = 20, delay: int = 15) -> None:
    """
    Called in a daemon thread.  Retries every `delay` seconds until
    create_all() succeeds or max_attempts is exhausted.
    20 attempts × 15 s = 5 minutes total patience.
    """
    global _db_ready, _db_init_error
    for attempt in range(1, max_attempts + 1):
        try:
            logger.info("DB init attempt %d/%d …", attempt, max_attempts)
            init_db()
            _db_ready = True
            _db_init_error = ""
            logger.info("✅ Database schema ready (attempt %d)", attempt)
            return
        except Exception as exc:
            _db_init_error = str(exc)
            logger.warning(
                "DB init attempt %d failed: %s — retrying in %ds",
                attempt, exc, delay
            )
            time.sleep(delay)

    logger.error("❌ DB init failed after %d attempts: %s", max_attempts, _db_init_error)


# ── Lifespan (replaces deprecated @app.on_event) ─────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("🚀 ShimonVault %s starting up (env: %s)", APP_VERSION, ENVIRONMENT)

    # Fire-and-forget background DB initialisation.
    # daemon=True means this thread will not prevent process shutdown.
    t = threading.Thread(target=_init_db_with_retry, daemon=True, name="db-init")
    t.start()

    yield  # app runs here

    logger.info("ShimonVault shutting down.")


# ── App instance ──────────────────────────────────────────────────────────────
app = FastAPI(
    title="ShimonVault",
    description="Secure internal operations platform",
    version=APP_VERSION,
    lifespan=lifespan,
)

# ── CORS ──────────────────────────────────────────────────────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],      # tighten in production if needed
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Prometheus metrics ────────────────────────────────────────────────────────
Instrumentator().instrument(app).expose(app, endpoint="/metrics")

# ── Routers ───────────────────────────────────────────────────────────────────
from routers.auth_router     import router as auth_router      # noqa: E402
from routers.docs_router     import router as docs_router      # noqa: E402
from routers.meetings_router import router as meetings_router  # noqa: E402
from routers.audit_router    import router as audit_router     # noqa: E402

app.include_router(auth_router,     prefix="/auth",     tags=["auth"])
app.include_router(docs_router,     prefix="/docs",     tags=["docs"])
app.include_router(meetings_router, prefix="/meetings", tags=["meetings"])
app.include_router(audit_router,    prefix="/audit",    tags=["audit"])


# ── Health endpoint ───────────────────────────────────────────────────────────
@app.get("/health", tags=["health"])
def health_check():
    """
    Always returns HTTP 200 so the ALB health check passes immediately.

    The 'db' field tells you whether the database is also ready:
      - "initialising" → background thread is still retrying (normal for
        the first 1-3 minutes after a fresh EC2 boot)
      - "ok"           → schema created, connections working
      - "error: …"     → something is wrong; check /logs

    The ALB only cares about the HTTP status code (200), not the body.
    """
    if _db_ready:
        db_status = "ok"
    elif _db_init_error:
        db_status = f"error: {_db_init_error[:120]}"
    else:
        db_status = "initialising"

    return {
        "status": "healthy",
        "version": APP_VERSION,
        "project": PROJECT_NAME,
        "environment": ENVIRONMENT,
        "db": db_status,
    }


# ── Root ──────────────────────────────────────────────────────────────────────
@app.get("/", tags=["root"])
def root():
    return {
        "project": PROJECT_NAME,
        "version": APP_VERSION,
        "docs": "/docs",
        "health": "/health",
        "metrics": "/metrics",
    }
