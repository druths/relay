"""ElevenLabs TTS provider."""

from __future__ import annotations

import logging

import httpx

from app.config import settings
from app.services.tts.base import TTSProvider

logger = logging.getLogger(__name__)

_clients: dict[str, httpx.AsyncClient] = {}

ELEVENLABS_BASE_URL = "https://api.elevenlabs.io/v1"


def _get_client(api_key: str | None = None) -> httpx.AsyncClient | None:
    effective_key = api_key or settings.elevenlabs_api_key
    logger.info(
        "ElevenLabs _get_client: api_key_len=%s, env_key_len=%s, effective_len=%s",
        len(api_key) if api_key else 0,
        len(settings.elevenlabs_api_key) if settings.elevenlabs_api_key else 0,
        len(effective_key) if effective_key else 0,
    )
    if not effective_key:
        logger.warning("ElevenLabs _get_client: no API key available")
        return None
    is_new = effective_key not in _clients
    if is_new:
        _clients[effective_key] = httpx.AsyncClient(
            base_url=ELEVENLABS_BASE_URL,
            headers={"xi-api-key": effective_key},
            timeout=60.0,
        )
    logger.info("ElevenLabs _get_client: key_prefix=%s, new_client=%s", effective_key[:8], is_new)
    return _clients[effective_key]


class ElevenLabsTTSProvider(TTSProvider):
    DEFAULT_MODEL = "eleven_multilingual_v2"

    def __init__(self, api_key: str | None = None):
        self._api_key = api_key

    @classmethod
    def available_voices(cls) -> list[dict]:
        # ElevenLabs voices are dynamic (account-specific).
        # Use fetch_voices() with an API key instead.
        return []

    @classmethod
    async def fetch_voices(cls, api_key: str, model_id: str | None = None) -> list[dict]:
        """Fetch voices from the ElevenLabs API, optionally filtered by model compatibility."""
        client = _get_client(api_key)
        if client is None:
            return []
        try:
            resp = await client.get("/voices")
            resp.raise_for_status()
            data = resp.json()
            voices = []
            for v in data.get("voices", []):
                # Filter by model compatibility if requested
                if model_id:
                    supported = v.get("high_quality_base_model_ids", [])
                    if supported and model_id not in supported:
                        continue
                labels = v.get("labels", {})
                desc = ", ".join(labels.values()) if labels else ""
                voices.append({
                    "id": v["voice_id"],
                    "name": v.get("name", v["voice_id"]),
                    "description": desc or "Custom voice",
                })
            return voices
        except Exception as exc:
            logger.warning("Failed to fetch ElevenLabs voices: %s", exc)
            return []

    async def synthesize(self, text: str, voice_id: str, voice_settings: dict) -> bytes:
        client = _get_client(self._api_key)
        if client is None:
            raise RuntimeError("ElevenLabs API key not configured")

        model_id = voice_settings.get("model_id", self.DEFAULT_MODEL)
        stability = voice_settings.get("stability", 0.5)
        similarity_boost = voice_settings.get("similarity_boost", 0.75)

        logger.info(
            "ElevenLabs TTS: voice=%s, model=%s, stability=%.2f, similarity=%.2f, %d chars",
            voice_id, model_id, stability, similarity_boost, len(text),
        )

        resp = await client.post(
            f"/text-to-speech/{voice_id}",
            json={
                "text": text,
                "model_id": model_id,
                "voice_settings": {
                    "stability": stability,
                    "similarity_boost": similarity_boost,
                },
            },
            headers={"Accept": "audio/mpeg"},
        )
        if resp.status_code != 200:
            body = resp.text[:500]
            logger.error(
                "ElevenLabs TTS error: status=%d, voice=%s, chars=%d, body=%s",
                resp.status_code, voice_id, len(text), body,
            )
            resp.raise_for_status()
        logger.info("ElevenLabs TTS: got %d bytes for %d chars", len(resp.content), len(text))
        return resp.content
