"""ElevenLabs Scribe STT provider."""

from __future__ import annotations

import logging

import httpx

from app.config import settings
from app.services.stt.base import STTProvider

logger = logging.getLogger(__name__)

_clients: dict[str, httpx.AsyncClient] = {}

ELEVENLABS_BASE_URL = "https://api.elevenlabs.io/v1"


def _get_client(api_key: str | None = None) -> httpx.AsyncClient | None:
    effective_key = api_key or settings.elevenlabs_api_key
    if not effective_key:
        return None
    if effective_key not in _clients:
        _clients[effective_key] = httpx.AsyncClient(
            base_url=ELEVENLABS_BASE_URL,
            headers={"xi-api-key": effective_key},
            timeout=60.0,
        )
    return _clients[effective_key]


class ElevenLabsSTTProvider(STTProvider):
    DEFAULT_MODEL = "scribe_v1"

    def __init__(self, api_key: str | None = None):
        self._api_key = api_key

    async def transcribe(
        self,
        audio_bytes: bytes,
        format: str = "webm",
        no_speech_threshold: float = 0.5,
    ) -> str:
        client = _get_client(self._api_key)
        if client is None:
            raise RuntimeError("ElevenLabs API key not configured for STT")

        logger.info(
            "ElevenLabs STT: %d bytes, format=%s",
            len(audio_bytes), format,
        )

        resp = await client.post(
            "/speech-to-text",
            data={"model_id": self.DEFAULT_MODEL, "tag_audio_events": "false"},
            files={"file": (f"audio.{format}", audio_bytes)},
        )

        if resp.status_code != 200:
            body = resp.text[:500]
            logger.error(
                "ElevenLabs STT error: status=%d, body=%s",
                resp.status_code, body,
            )
            resp.raise_for_status()

        result = resp.json()
        text = result.get("text", "").strip()

        if text:
            logger.info(
                "ElevenLabs STT result: %d chars — %r",
                len(text), text[:120],
            )
        else:
            logger.info("ElevenLabs STT: no usable speech detected")

        return text
