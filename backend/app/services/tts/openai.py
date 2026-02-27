"""OpenAI TTS provider."""

from __future__ import annotations

import logging

from openai import AsyncOpenAI

from app.config import settings
from app.services.tts.base import TTSProvider

logger = logging.getLogger(__name__)

_clients: dict[str, AsyncOpenAI] = {}


def _get_client(api_key: str | None = None) -> AsyncOpenAI | None:
    effective_key = api_key or settings.openai_api_key
    if not effective_key:
        return None
    if effective_key not in _clients:
        _clients[effective_key] = AsyncOpenAI(api_key=effective_key)
    return _clients[effective_key]


class OpenAITTSProvider(TTSProvider):
    def __init__(self, api_key: str | None = None):
        self._api_key = api_key

    @classmethod
    def available_voices(cls) -> list[dict]:
        return [
            {"id": "alloy", "name": "Alloy", "description": "Neutral and balanced"},
            {"id": "ash", "name": "Ash", "description": "Soft and conversational"},
            {"id": "ballad", "name": "Ballad", "description": "Warm and expressive"},
            {"id": "coral", "name": "Coral", "description": "Clear and engaging"},
            {"id": "echo", "name": "Echo", "description": "Warm and deep"},
            {"id": "fable", "name": "Fable", "description": "Expressive and animated"},
            {"id": "nova", "name": "Nova", "description": "Bright and energetic"},
            {"id": "onyx", "name": "Onyx", "description": "Deep and authoritative"},
            {"id": "sage", "name": "Sage", "description": "Calm and measured"},
            {"id": "shimmer", "name": "Shimmer", "description": "Light and friendly"},
        ]

    async def synthesize(self, text: str, voice_id: str, voice_settings: dict) -> bytes:
        client = _get_client(self._api_key)
        if client is None:
            raise RuntimeError("OpenAI API key not configured")

        speed = voice_settings.get("speed", 1.0)
        model = voice_settings.get("model", "tts-1")

        logger.info("OpenAI TTS: voice=%s, speed=%.1f, %d chars", voice_id, speed, len(text))

        response = await client.audio.speech.create(
            model=model,
            voice=voice_id,
            input=text,
            response_format="mp3",
            speed=speed,
        )

        return response.read()
