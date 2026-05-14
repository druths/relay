import json

import redis.asyncio as redis

from app.config import settings

pool = redis.ConnectionPool.from_url(settings.redis_url, decode_responses=True)


def get_redis() -> redis.Redis:
    return redis.Redis(connection_pool=pool)


async def cache_session_context(session_id: str, messages: list[dict]) -> None:
    """Mirror active session messages in Redis for low-latency reads."""
    r = get_redis()
    await r.set(f"session:{session_id}:context", json.dumps(messages), ex=3600)


async def get_cached_context(session_id: str) -> list[dict] | None:
    """Retrieve cached session context from Redis."""
    r = get_redis()
    data = await r.get(f"session:{session_id}:context")
    if data:
        return json.loads(data)
    return None


async def invalidate_session_cache(session_id: str) -> None:
    r = get_redis()
    await r.delete(f"session:{session_id}:context")


async def get_provider_state(session_id: str, provider: str) -> str | None:
    """Get per-provider continuation state for a session (e.g. an OpenClaw
    response_id or an ark session_id). Returns None if absent."""
    from sqlalchemy import select
    from app.db.database import async_session
    from app.models.session import Session
    import uuid

    async with async_session() as db:
        result = await db.execute(
            select(Session.provider_state).where(Session.session_id == uuid.UUID(session_id))
        )
        state = result.scalar_one_or_none() or {}
        value = state.get(provider)
        return value if isinstance(value, str) else None


async def set_provider_state(session_id: str, provider: str, value: str) -> None:
    """Store per-provider continuation state for a session."""
    from sqlalchemy import select
    from app.db.database import async_session
    from app.models.session import Session
    import uuid

    async with async_session() as db:
        result = await db.execute(
            select(Session).where(Session.session_id == uuid.UUID(session_id))
        )
        session = result.scalar_one_or_none()
        if session is None:
            return
        # Copy-then-assign so SQLAlchemy detects the JSONB mutation.
        new_state = dict(session.provider_state or {})
        new_state[provider] = value
        session.provider_state = new_state
        await db.commit()


# ── Legacy single-provider shims ─────────────────────────────────────
# Existing callers continue to work while we migrate them over.

async def get_openclaw_response_id(session_id: str) -> str | None:
    return await get_provider_state(session_id, "openclaw")


async def set_openclaw_response_id(session_id: str, response_id: str) -> None:
    await set_provider_state(session_id, "openclaw", response_id)
