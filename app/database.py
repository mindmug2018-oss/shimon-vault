"""
database.py — ShimonVault database engine and session factory

KEY RULES (do not change without understanding why):

1. URL scheme MUST be postgresql+psycopg2://
   asyncpg (postgresql+asyncpg://) requires create_async_engine and an
   async runtime.  Using it with the synchronous create_engine raises
   MissingGreenlet and crashes the app on startup.

2. Engines are created LAZILY (only when first used).
   create_all() is called from a background thread in main.py with retry
   logic.  This means /health returns 200 immediately even when RDS is
   still initialising (takes 30-60 s after the EC2 boots).

3. connect_timeout=10 is set so a failed connection attempt fails fast
   instead of hanging for the default 30+ seconds.

4. WRITE_DB_URL  → AWS RDS primary  (all INSERT / UPDATE / DELETE)
   READ_DB_URL   → on-prem replica  (SELECT queries where available)
   Both fall back to the same local URL when env vars are missing so
   tests work without a real database.
"""

from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from config import WRITE_DB_URL, READ_DB_URL
import logging

logger = logging.getLogger(__name__)


# ── ORM base ──────────────────────────────────────────────────────────────────

class Base(DeclarativeBase):
    pass


# ── Engine factory (lazy) ─────────────────────────────────────────────────────

_write_engine = None
_read_engine  = None


def _make_engine(url: str, label: str):
    """Create a SQLAlchemy engine.  connect_timeout prevents indefinite hangs."""
    logger.info("Creating %s engine → %s", label, url.split("@")[-1])  # hide credentials
    return create_engine(
        url,
        pool_pre_ping=True,          # cheap 'SELECT 1' before handing out connections
        pool_recycle=1800,           # recycle connections every 30 min
        connect_args={"connect_timeout": 10},
        echo=False,
    )


def get_write_engine():
    global _write_engine
    if _write_engine is None:
        _write_engine = _make_engine(WRITE_DB_URL, "WRITE")
    return _write_engine


def get_read_engine():
    global _read_engine
    if _read_engine is None:
        _read_engine = _make_engine(READ_DB_URL, "READ")
    return _read_engine


# ── Session factories ─────────────────────────────────────────────────────────

def _WriteSessionLocal():
    factory = sessionmaker(
        autocommit=False,
        autoflush=False,
        bind=get_write_engine(),
    )
    return factory()


def _ReadSessionLocal():
    factory = sessionmaker(
        autocommit=False,
        autoflush=False,
        bind=get_read_engine(),
    )
    return factory()


# ── FastAPI dependency helpers ────────────────────────────────────────────────

def get_write_db():
    """Yield a write (RDS primary) session.  Use for all mutations."""
    db = _WriteSessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_read_db():
    """Yield a read (on-prem replica) session.  Use for SELECT-only routes."""
    db = _ReadSessionLocal()
    try:
        yield db
    finally:
        db.close()


# ── Schema initialisation (called from background thread in main.py) ──────────

def init_db():
    """
    Create all tables if they do not exist.
    This is intentionally called from a background thread with retry logic
    so it never blocks the /health endpoint on startup.
    """
    # Import models here to ensure they are registered with Base before
    # create_all() is called.  Circular-import safe because we import
    # inside the function.
    import models  # noqa: F401

    logger.info("Running Base.metadata.create_all() against write engine …")
    Base.metadata.create_all(bind=get_write_engine())
    logger.info("Database schema ready.")


def check_db_connection() -> bool:
    """Return True if the write DB is reachable.  Used by /health."""
    try:
        with get_write_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception as exc:
        logger.warning("DB health check failed: %s", exc)
        return False
