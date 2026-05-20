"""Durable catch-up cursor for ark's `GET /events?since_id=...` endpoint.

Stored as a PlatformSetting with key `ark_cursor:<server_id>` where
`server_id` is a stable hash of the (base_url, api_key) pair. One cursor
per ark server connection.
"""

from __future__ import annotations

import logging

from sqlalchemy import select

from app.db.database import async_session
from app.models.platform_setting import PlatformSetting

logger = logging.getLogger(__name__)


def _key(server_id: str) -> str:
    return f"ark_cursor:{server_id}"


async def get_cursor(server_id: str) -> int | None:
    async with async_session() as db:
        result = await db.execute(
            select(PlatformSetting).where(PlatformSetting.key == _key(server_id))
        )
        row = result.scalar_one_or_none()
        if not row or not row.value:
            return None
        try:
            return int(row.value)
        except ValueError:
            logger.warning("Ark cursor %s has non-int value %r", server_id, row.value)
            return None


async def set_cursor(server_id: str, value: int) -> None:
    async with async_session() as db:
        result = await db.execute(
            select(PlatformSetting).where(PlatformSetting.key == _key(server_id))
        )
        row = result.scalar_one_or_none()
        if row:
            row.value = str(value)
        else:
            db.add(PlatformSetting(key=_key(server_id), value=str(value)))
        await db.commit()
