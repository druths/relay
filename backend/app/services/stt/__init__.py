"""STT provider factory."""

from __future__ import annotations

from app.services.stt.base import STTProvider


def get_stt_provider() -> STTProvider | None:
    """Return the first available STT provider, or None."""
    from app.services.stt.openai import OpenAISTTProvider, _get_client

    if _get_client() is not None:
        return OpenAISTTProvider()

    return None


def is_stt_available() -> bool:
    """Check if any STT provider is configured."""
    return get_stt_provider() is not None
