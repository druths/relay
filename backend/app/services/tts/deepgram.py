"""Deepgram Aura text-to-speech provider.

The voice is the model: `aura-2-thalia-en`, `aura-2-orion-en`, etc.
"""

from __future__ import annotations

import logging
import re

import httpx

from app.config import settings
from app.services.tts.base import TTSProvider

logger = logging.getLogger(__name__)

DEEPGRAM_BASE_URL = "https://api.deepgram.com/v1"
# Deepgram rejects speak requests over 2000 characters.
MAX_CHARS = 1900

_client: httpx.AsyncClient | None = None


def _http() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(base_url=DEEPGRAM_BASE_URL, timeout=60.0)
    return _client


def _key_for(api_key: str | None) -> str | None:
    return api_key or settings.deepgram_api_key or None


def _split_text(text: str, limit: int = MAX_CHARS) -> list[str]:
    """Split on sentence boundaries into chunks under `limit`; hard-wrap any
    single sentence that is itself too long."""
    chunks: list[str] = []
    current = ""
    for sentence in re.split(r"(?<=[.!?])\s+", text.strip()):
        while len(sentence) > limit:
            cut = sentence.rfind(" ", 0, limit)
            cut = cut if cut > 0 else limit
            if current:
                chunks.append(current)
                current = ""
            chunks.append(sentence[:cut])
            sentence = sentence[cut:].lstrip()
        if current and len(current) + 1 + len(sentence) > limit:
            chunks.append(current)
            current = sentence
        else:
            current = f"{current} {sentence}" if current else sentence
    if current:
        chunks.append(current)
    return chunks


class DeepgramTTSProvider(TTSProvider):
    DEFAULT_VOICE = "aura-2-thalia-en"

    def __init__(self, api_key: str | None = None):
        self._api_key = api_key

    @classmethod
    def available_voices(cls) -> list[dict]:
        return []

    @classmethod
    async def fetch_voices(cls, api_key: str) -> list[dict]:
        """Aura voices from Deepgram's model catalogue: Aura-2 English first,
        then other Aura-2 languages, then Aura-1."""
        key = _key_for(api_key)
        if key is None:
            return []
        try:
            resp = await _http().get("/models", headers={"Authorization": f"Token {key}"})
            resp.raise_for_status()
            models = resp.json().get("tts") or []
        except Exception as exc:
            logger.warning("Deepgram fetch_voices failed: %s", exc)
            return []

        out: list[dict] = []
        for m in models:
            voice_id = m.get("canonical_name")
            if not voice_id:
                continue
            arch = m.get("architecture") or ""
            langs = m.get("languages") or []
            meta = m.get("metadata") or {}
            description = " · ".join(p for p in [
                "Aura 2" if arch == "aura-2" else "Aura",
                ", ".join(langs),
                meta.get("accent"),
                ", ".join((meta.get("tags") or [])[:3]),
            ] if p)
            rank = (0 if arch == "aura-2" else 1, 0 if any(l.startswith("en") for l in langs) else 1)
            out.append({
                "id": voice_id,
                "name": (m.get("name") or voice_id).title(),
                "description": description,
                "_rank": rank,
            })
        out.sort(key=lambda v: (v["_rank"], v["name"]))
        for v in out:
            v.pop("_rank")
        return out

    async def synthesize(self, text: str, voice_id: str, voice_settings: dict) -> bytes:
        key = _key_for(self._api_key)
        if key is None:
            raise RuntimeError("Deepgram API key not configured")

        params: dict = {"model": voice_id or self.DEFAULT_VOICE, "encoding": "mp3"}
        speed = float(voice_settings.get("speed", 1.0))
        if speed != 1.0:
            params["speed"] = speed
        headers = {"Authorization": f"Token {key}"}

        logger.info("Deepgram TTS: voice=%s, speed=%.2f, %d chars", params["model"], speed, len(text))

        # MP3 frames concatenate cleanly, so long text is synthesized per
        # chunk and joined.
        audio = b""
        for chunk in _split_text(text):
            resp = await _http().post("/speak", params=params, headers=headers, json={"text": chunk})
            if resp.status_code != 200:
                logger.error(
                    "Deepgram TTS error: status=%d, voice=%s, chars=%d, body=%s",
                    resp.status_code, params["model"], len(chunk), resp.text[:500],
                )
                resp.raise_for_status()
            audio += resp.content
        return audio
