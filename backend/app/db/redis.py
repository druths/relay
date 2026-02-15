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
