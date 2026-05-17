"""STT provider factory and UI schema registry.

Schemas here are the single source of truth for the client picker — see
`/v1/agents/stt/providers`. Adding a provider means editing PROVIDER_SCHEMAS
below and (if it needs a server-side implementation) get_stt_provider().
"""

from __future__ import annotations

import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.platform_setting import PlatformSetting
from app.services.stt.base import STTProvider

logger = logging.getLogger(__name__)


PROVIDER_SCHEMAS: list[dict] = [
    {
        "id": "apple",
        "label": "Apple (On-Device)",
        "fields": [],
        "client_only": True,  # STT happens on the device, no server provider
    },
    {
        "id": "openai",
        "label": "OpenAI (Whisper)",
        # STT has no per-agent fields, but the API key is platform-defaultable
        # via this entry — it shows up in the Provider Defaults tab.
        "fields": [
            {"key": "stt_api_key", "label": "API Key", "type": "password",
             "placeholder": "sk-…",
             "platform_key": "stt_openai_api_key"},
        ],
    },
    {
        "id": "elevenlabs",
        "label": "ElevenLabs (Scribe)",
        "fields": [
            {"key": "stt_api_key", "label": "API Key", "type": "password",
             "placeholder": "xi-…",
             "platform_key": "stt_elevenlabs_api_key"},
        ],
    },
]


def list_provider_schemas() -> list[dict]:
    return PROVIDER_SCHEMAS


def get_stt_provider(
    provider_name: str = "openai",
    api_key: str | None = None,
) -> STTProvider | None:
    """Return an STT provider instance, or None if unavailable."""
    if provider_name == "openai":
        from app.services.stt.openai import OpenAISTTProvider, _get_client

        if _get_client(api_key) is not None:
            return OpenAISTTProvider(api_key=api_key)
        return None

    if provider_name == "elevenlabs":
        from app.services.stt.elevenlabs import ElevenLabsSTTProvider, _get_client

        if _get_client(api_key) is not None:
            return ElevenLabsSTTProvider(api_key=api_key)
        return None

    logger.debug("get_stt_provider: unknown provider=%s", provider_name)
    return None


async def get_stt_provider_from_db(db: AsyncSession) -> STTProvider | None:
    """Return an STT provider using the platform settings from the DB."""
    # Read provider name
    result = await db.execute(
        select(PlatformSetting).where(PlatformSetting.key == "stt_provider")
    )
    row = result.scalar_one_or_none()
    provider_name = (row.value if row and row.value else "") or "openai"

    # Read STT API key
    result = await db.execute(
        select(PlatformSetting).where(PlatformSetting.key == "stt_api_key")
    )
    row = result.scalar_one_or_none()
    api_key = row.value if row and row.value else None

    # ElevenLabs fallback: stt_api_key -> tts_elevenlabs_api_key -> env var
    if provider_name == "elevenlabs" and not api_key:
        result = await db.execute(
            select(PlatformSetting).where(
                PlatformSetting.key == "tts_elevenlabs_api_key"
            )
        )
        row = result.scalar_one_or_none()
        api_key = row.value if row and row.value else None

    return get_stt_provider(provider_name, api_key)


def is_stt_available() -> bool:
    """Check if any STT provider is configured (env-var fallback only)."""
    return get_stt_provider() is not None
