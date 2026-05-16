"""TTS provider factory and UI schema registry.

The schemas listed below are the single source of truth for what providers
the clients (web, iOS) offer in their picker, and what fields each requires.
Clients fetch this list from `/v1/agents/tts/providers` on demand — no need
to ship a client update when a provider is added/removed/edited.
"""

from __future__ import annotations

import logging

from app.services.tts.base import TTSProvider

logger = logging.getLogger(__name__)


# Order here is the order in the picker.
PROVIDER_SCHEMAS: list[dict] = [
    {
        "id": "none",
        "label": "None (No TTS)",
        "fields": [],
    },
    {
        "id": "openai",
        "label": "OpenAI-Compatible",
        "fields": [
            {"key": "tts_api_key", "label": "API Key", "type": "password",
             "placeholder": "sk-… (blank for local TTS)"},
            {"key": "base_url", "label": "Base URL", "type": "text",
             "placeholder": "Blank for OpenAI, or http://kokoro:8880 for local"},
        ],
    },
    {
        "id": "elevenlabs",
        "label": "ElevenLabs",
        "fields": [
            {"key": "tts_api_key", "label": "API Key", "type": "password",
             "placeholder": "xi-… (uses platform key if blank)"},
        ],
    },
    {
        "id": "google",
        "label": "Google (Chirp 3 HD)",
        "fields": [
            {"key": "tts_api_key", "label": "API Key", "type": "password",
             "placeholder": "AIza… (uses platform key if blank)"},
        ],
    },
    {
        "id": "neutts",
        "label": "NeuTTS (self-hosted)",
        "fields": [
            {"key": "base_url", "label": "Server URL", "type": "text",
             "placeholder": "Blank to use default neutts:8000"},
        ],
    },
]


def list_provider_schemas() -> list[dict]:
    return PROVIDER_SCHEMAS


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

    if provider_name == "neutts":
        from app.services.tts.neutts import NeuTTSProvider

        return NeuTTSProvider(base_url=base_url)

    if provider_name == "google":
        from app.services.tts.google import GoogleTTSProvider, _get_client as _get_google_client

        if _get_google_client(api_key) is None:
            logger.warning("get_tts_provider: Google client is None (no key)")
            return None
        return GoogleTTSProvider(api_key=api_key)

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

    if provider_name == "neutts":
        from app.services.tts.neutts import NeuTTSProvider

        # `api_key` slot is unused for NeuTTS; the optional override URL is
        # carried via the agent's voice_settings.base_url which we don't have
        # access to here. Server URL falls back to settings/env.
        return await NeuTTSProvider.fetch_voices()

    if provider_name == "google":
        from app.services.tts.google import GoogleTTSProvider

        return await GoogleTTSProvider.fetch_voices(api_key)

    return []
