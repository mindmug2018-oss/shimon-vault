# shimon-vault/app/rate_limit.py
"""
rate_limit.py — single shared slowapi Limiter instance.

Every router that uses @limiter.limit(...) must import THIS limiter,
not create its own. A Limiter instance that is never attached to the
FastAPI app via app.state.limiter + SlowAPIMiddleware silently does
nothing -- the decorator runs but never actually enforces a limit.
"""
from slowapi import Limiter
from slowapi.util import get_remote_address

# key_style="endpoint" is required for any route with a path parameter
# (e.g. /docs/download/{doc_id}). slowapi's DEFAULT key_style is "url",
# which keys the rate-limit counter on the literal resolved URL
# (e.g. "/docs/download/doc-0001"). Every different doc_id then becomes a
# brand-new, never-before-seen key, so the per-IP counter never accumulates
# past 1 and the limit never triggers -- discovered when a bulk-download
# simulation against 50 different fake IDs never hit 429, while repeating
# the SAME id did. key_style="endpoint" keys on the route's function name
# instead, which is shared across all values of {doc_id}.
limiter = Limiter(key_func=get_remote_address, key_style="endpoint")
