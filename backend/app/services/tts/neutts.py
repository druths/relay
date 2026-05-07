"""NeuTTS provider — talks to the self-hosted neutts-server container."""

from __future__ import annotations

import logging

import httpx

from app.config import settings
from app.services.tts.base import TTSProvider

logger = logging.getLogger(__name__)

_clients: dict[str, httpx.AsyncClient] = {}
_voices_cache: dict[str, list[dict]] = {}

DEFAULT_BASE_URL = "http://neutts:8000"


def _resolve_base_url(base_url: str | None) -> str:
    return (base_url or getattr(settings, "neutts_url", None) or DEFAULT_BASE_URL).rstrip("/")


def _get_client(base_url: str | None) -> httpx.AsyncClient:
    """Cache one keep-alive httpx client per base URL so we're not paying TCP
    handshake on every per-sentence synthesize call."""
    url = _resolve_base_url(base_url)
    if url not in _clients:
        _clients[url] = httpx.AsyncClient(base_url=url, timeout=60.0)
    return _clients[url]


class NeuTTSProvider(TTSProvider):
    def __init__(self, base_url: str | None = None):
        self._base_url = base_url

    @classmethod
    def available_voices(cls) -> list[dict]:
        # Voices are dynamic — fetched from the server at runtime.
        # The provider factory exposes them via fetch_voices_async.
        return []

    @classmethod
    async def fetch_voices(cls, base_url: str | None = None) -> list[dict]:
        url = _resolve_base_url(base_url)
        cached = _voices_cache.get(url)
        if cached is not None:
            return cached
        try:
            async with httpx.AsyncClient(base_url=url, timeout=10.0) as client:
                resp = await client.get("/voices")
                resp.raise_for_status()
                voices = resp.json()
        except Exception as e:
            logger.warning("NeuTTS fetch_voices failed for %s: %s", url, e)
            return []
        _voices_cache[url] = voices
        return voices

    async def synthesize(self, text: str, voice_id: str, voice_settings: dict) -> bytes:
        base_url = voice_settings.get("base_url") or self._base_url
        client = _get_client(base_url)
        speed = float(voice_settings.get("speed", 1.0))

        logger.info(
            "NeuTTS TTS: voice=%s, speed=%.2f, %d chars, base_url=%s",
            voice_id, speed, len(text), _resolve_base_url(base_url),
        )

        resp = await client.post("/synthesize", json={
            "text": text,
            "voice_id": voice_id,
            "speed": speed,
            "format": "mp3",
        })
        resp.raise_for_status()
        return resp.content
