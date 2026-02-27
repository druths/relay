"""Authentication — single-user JWT auth."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from app.config import settings

router = APIRouter(prefix="/v1/auth", tags=["auth"])

# Hash the configured password once at import time
_HASHED_PASSWORD = bcrypt.hashpw(
    settings.auth_password.encode(), bcrypt.gensalt()
)

_ALGORITHM = "HS256"
_TOKEN_EXPIRE_DAYS = 7
_bearer_scheme = HTTPBearer()


# ── Schemas ──────────────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


# ── Helpers ──────────────────────────────────────────────────────────────

def _create_token(username: str) -> str:
    payload = {
        "sub": username,
        "exp": datetime.now(timezone.utc) + timedelta(days=_TOKEN_EXPIRE_DAYS),
    }
    return jwt.encode(payload, settings.auth_jwt_secret, algorithm=_ALGORITHM)


def _verify_token(token: str) -> str:
    """Decode and validate a JWT. Returns the username."""
    try:
        payload = jwt.decode(
            token, settings.auth_jwt_secret, algorithms=[_ALGORITHM]
        )
        username: str | None = payload.get("sub")
        if username != settings.auth_username:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token"
            )
        return username
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired"
        )
    except jwt.InvalidTokenError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token"
        )


# ── Dependencies ─────────────────────────────────────────────────────────

def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer_scheme),
) -> str:
    """FastAPI dependency — validates Bearer token on REST endpoints."""
    return _verify_token(credentials.credentials)


def verify_ws_token(token: str) -> str:
    """Validate a JWT from a WebSocket query param.

    Returns the username or raises ValueError.
    """
    try:
        payload = jwt.decode(
            token, settings.auth_jwt_secret, algorithms=[_ALGORITHM]
        )
        username: str | None = payload.get("sub")
        if username != settings.auth_username:
            raise ValueError("Invalid token")
        return username
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError) as exc:
        raise ValueError(str(exc)) from exc


# ── Endpoints ────────────────────────────────────────────────────────────

@router.post("/login", response_model=LoginResponse)
async def login(body: LoginRequest):
    if (
        body.username != settings.auth_username
        or not bcrypt.checkpw(body.password.encode(), _HASHED_PASSWORD)
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
        )
    return LoginResponse(access_token=_create_token(body.username))


@router.get("/me")
async def me(username: str = Depends(get_current_user)):
    return {"username": username}
