"""TTS provider factory."""

from __future__ import annotations

from app.services.tts.base import TTSProvider


def get_tts_provider(provider_name: str) -> TTSProvider | None:
    """Return a TTS provider instance, or None if TTS is disabled."""
    if provider_name == "openai":
        from app.services.tts.openai import OpenAITTSProvider, _get_client

        if _get_client() is None:
            return None
        return OpenAITTSProvider()

    # "none" or unknown provider
    return None


def get_available_voices(provider_name: str) -> list[dict]:
    """Return available voices for a TTS provider."""
    if provider_name == "openai":
        from app.services.tts.openai import OpenAITTSProvider

        return OpenAITTSProvider.available_voices()

    return []
