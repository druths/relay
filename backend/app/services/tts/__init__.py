"""TTS provider factory."""

from __future__ import annotations

import logging

from app.services.tts.base import TTSProvider

logger = logging.getLogger(__name__)


def get_tts_provider(provider_name: str, api_key: str | None = None, base_url: str | None = None) -> TTSProvider | None:
    """Return a TTS provider instance, or None if TTS is disabled."""
    logger.info(
        "get_tts_provider: provider=%s, key_len=%s, base_url=%s",
        provider_name, len(api_key) if api_key else 0, base_url,
    )
    if provider_name == "openai":
        from app.services.tts.openai import OpenAITTSProvider, _get_client

        # Local TTS (e.g., Kokoro) doesn't need an API key
        if not base_url and _get_client(api_key) is None:
            logger.warning("get_tts_provider: OpenAI client is None (no key)")
            return None
        return OpenAITTSProvider(api_key=api_key, base_url=base_url)

    if provider_name == "elevenlabs":
        from app.services.tts.elevenlabs import ElevenLabsTTSProvider, _get_client

        client = _get_client(api_key)
        if client is None:
            logger.warning("get_tts_provider: ElevenLabs client is None (no key)")
            return None
        logger.info("get_tts_provider: ElevenLabs client ready")
        return ElevenLabsTTSProvider(api_key=api_key)

    # "none" or unknown provider
    logger.debug("get_tts_provider: unknown provider=%s", provider_name)
    return None


def get_available_voices(provider_name: str) -> list[dict]:
    """Return available voices for a TTS provider (static only)."""
    if provider_name == "openai":
        from app.services.tts.openai import OpenAITTSProvider

        return OpenAITTSProvider.available_voices()

    # ElevenLabs voices are dynamic — use fetch_voices_async instead.
    return []


async def fetch_voices_async(provider_name: str, api_key: str, model_id: str | None = None) -> list[dict]:
    """Fetch voices asynchronously (for providers that need API calls)."""
    if provider_name == "openai":
        from app.services.tts.openai import OpenAITTSProvider

        return OpenAITTSProvider.available_voices()

    if provider_name == "elevenlabs":
        from app.services.tts.elevenlabs import ElevenLabsTTSProvider

        return await ElevenLabsTTSProvider.fetch_voices(api_key, model_id=model_id)

    return []
