# shimon-vault/app/auth.py

"""
auth.py — ShimonVault authentication and authorization

Provides:
  create_access_token(data)    → creates a signed JWT
  get_current_user(token)      → FastAPI dependency: decodes JWT, returns User
  require_role(*roles)         → dependency factory: blocks request if role not allowed
  hash_password(plain)         → bcrypt hash
  verify_password(plain, hash) → bcrypt verify

How JWTs work (simple explanation):
  1. User sends correct email + password to POST /auth/login
  2. Server creates a token: {"sub": user_id, "role": "editor", "exp": timestamp}
     and signs it with JWT_SECRET_KEY so nobody can forge it
  3. Client stores the token and sends it in every request header:
     Authorization: Bearer <token>
  4. get_current_user() on every protected endpoint decodes + verifies the token
     No database lookup needed on every request — the token IS the credential
"""

import hashlib
import uuid as _uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy.orm import Session

import config
from database import get_read_db
from models import User, UserRole

# ─── Password hashing ────────────────────────────────────────────────────────
# bcrypt is intentionally slow (work factor 12) to make brute-force expensive.
# Never use MD5 or SHA-256 for passwords — they are too fast.
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(plain: str) -> str:
    # bcrypt hard limit is 72 bytes. SHA-256 the password first so long
    # passwords still get full entropy without truncation.
    truncated = hashlib.sha256(plain.encode()).hexdigest()
    return pwd_context.hash(truncated)


def verify_password(plain: str, hashed: str) -> bool:
    truncated = hashlib.sha256(plain.encode()).hexdigest()
    return pwd_context.verify(truncated, hashed)


# ─── JWT ─────────────────────────────────────────────────────────────────────
bearer_scheme = HTTPBearer()


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    """
    Create a signed JWT.
    data should contain at least: {"sub": str(user.id), "role": user.role}
    """
    payload = data.copy()
    expire = datetime.now(timezone.utc) + (
        expires_delta or timedelta(minutes=config.JWT_EXPIRE_MINUTES)
    )
    payload.update({"exp": expire})
    return jwt.encode(payload, config.JWT_SECRET_KEY, algorithm=config.JWT_ALGORITHM)


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    db: Session = Depends(get_read_db),
) -> User:
    """
    FastAPI dependency. Use with: current_user: User = Depends(get_current_user)

    Decodes the JWT from the Authorization header.
    Looks up the user in the database to make sure they are still active.
    Raises HTTP 401 if the token is invalid, expired, or the user is suspended.
    """
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired token",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(
            credentials.credentials,
            config.JWT_SECRET_KEY,
            algorithms=[config.JWT_ALGORITHM],
        )
        user_id: str = payload.get("sub")
        if user_id is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception

    user = db.query(User).filter(User.id == _uuid.UUID(user_id)).first()
    if user is None or not user.is_active or user.suspended:
        raise credentials_exception

    return user


# ─── Role-based access control ───────────────────────────────────────────────

def require_role(*allowed_roles: UserRole):
    """
    Dependency factory. Use in route definitions like:

      @router.delete("/docs/{doc_id}")
      def delete_doc(
          doc_id: str,
          current_user: User = Depends(require_role(UserRole.ADMIN, UserRole.EDITOR))
      ):
          ...

    Returns HTTP 403 Forbidden if the user's role is not in allowed_roles.
    Violation tracking and account suspension are handled by
    middleware/audit_middleware.py, not here.
    """
    def dependency(current_user: User = Depends(get_current_user)) -> User:
        if current_user.role not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Access denied: requires one of {[r.value for r in allowed_roles]}",
            )
        return current_user
    return dependency
