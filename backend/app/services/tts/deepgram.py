"""Deepgram text-to-speech provider (Aura and Flux).

The voice is the model: `aura-2-thalia-en`, `flux-alexis-en`, etc. Aura
lives on the v1 API (`/v1/models`, `/v1/speak`); Flux only on v2
(`/v2/models`, `/v2/speak`), which also takes an `expressivity` control.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from collections.abc import AsyncIterator
from urllib.parse import urlencode

import httpx
import websockets

from app.config import settings
from app.services.tts.base import TTSProvider, TTSStream

logger = logging.getLogger(__name__)

DEEPGRAM_BASE_URL = "https://api.deepgram.com"
DEEPGRAM_WS_URL = "wss://api.deepgram.com"
STREAM_SAMPLE_RATE = 24000
# Once all text is sent, give up if Deepgram goes this long without a frame.
STREAM_DRAIN_TIMEOUT = 15.0
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


def _is_flux(voice_id: str) -> bool:
    return voice_id.startswith("flux-")


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


class DeepgramTTSStream(TTSStream):
    """Deepgram's streaming speak WebSocket (v1 for Aura, v2 for Flux).

    Both synthesize at sentence boundaries as text arrives, so the only
    Flush is the one in `finish()` — which also keeps us under Aura's
    20-flushes-per-minute limit. The end of the reply's audio is marked by
    `Flushed` on v1 and `SpeechMetadata` on v2.
    """

    sample_rate = STREAM_SAMPLE_RATE

    def __init__(self, ws, flux: bool):
        self._ws = ws
        self._flux = flux
        self._finished = False

    async def send(self, text: str) -> None:
        await self._ws.send(json.dumps({"type": "Speak", "text": text}))

    async def finish(self) -> None:
        await self._ws.send(json.dumps({"type": "Flush"}))
        self._finished = True

    async def audio(self) -> AsyncIterator[bytes]:
        while True:
            # No timeout while text may still be coming: an agent can pause
            # mid-reply (tool calls) for longer than any sane limit.
            timeout = STREAM_DRAIN_TIMEOUT if self._finished else None
            try:
                msg = await asyncio.wait_for(self._ws.recv(), timeout)
            except websockets.ConnectionClosedOK:
                return
            if isinstance(msg, bytes):
                yield msg
                continue
            event = json.loads(msg)
            etype = event.get("type")
            if etype == "Error":
                raise RuntimeError(f"Deepgram stream error {event.get('code')}: {event.get('description')}")
            if etype == "Warning":
                logger.warning("Deepgram stream warning: %s", event)
            elif etype == ("SpeechMetadata" if self._flux else "Flushed"):
                return

    async def aclose(self) -> None:
        try:
            await self._ws.send(json.dumps({"type": "Close"}))
        except Exception:
            pass
        await self._ws.close()


class DeepgramTTSProvider(TTSProvider):
    DEFAULT_VOICE = "aura-2-thalia-en"

    def __init__(self, api_key: str | None = None):
        self._api_key = api_key

    async def open_stream(self, voice_id: str, voice_settings: dict) -> DeepgramTTSStream:
        key = _key_for(self._api_key)
        if key is None:
            raise RuntimeError("Deepgram API key not configured")
        model = voice_id or self.DEFAULT_VOICE
        flux = _is_flux(model)
        params: dict = {"model": model, "encoding": "linear16", "sample_rate": STREAM_SAMPLE_RATE}
        speed = float(voice_settings.get("speed", 1.0))
        if speed != 1.0:
            params["speed"] = speed
        expressivity = int(voice_settings.get("expressivity", 0)) if flux else 0
        if expressivity:
            params["expressivity"] = max(-2, min(2, expressivity))
        url = f"{DEEPGRAM_WS_URL}/{'v2' if flux else 'v1'}/speak?{urlencode(params)}"
        logger.info("Deepgram TTS stream: voice=%s, expressivity=%d", model, expressivity)
        # websockets pings every 20s by default, which also keeps Deepgram's
        # 60s inactivity timer from closing the stream during a long pause.
        ws = await websockets.connect(
            url, additional_headers={"Authorization": f"Token {key}"}, open_timeout=10,
        )
        return DeepgramTTSStream(ws, flux)

    @classmethod
    def available_voices(cls) -> list[dict]:
        return []

    @classmethod
    async def fetch_voices(cls, api_key: str) -> list[dict]:
        """Voices from both of Deepgram's model catalogues (v1 = Aura,
        v2 = Flux). English first; within a language Flux, then Aura-2,
        then Aura-1. Either catalogue failing still returns the other."""
        key = _key_for(api_key)
        if key is None:
            return []
        headers = {"Authorization": f"Token {key}"}

        async def _catalogue(path: str) -> list[dict]:
            try:
                resp = await _http().get(path, headers=headers)
                resp.raise_for_status()
                return resp.json().get("tts") or []
            except Exception as exc:
                logger.warning("Deepgram fetch_voices %s failed: %s", path, exc)
                return []

        v1, v2 = await asyncio.gather(_catalogue("/v1/models"), _catalogue("/v2/models"))

        out: list[dict] = []
        seen: set[str] = set()
        for m in v2 + v1:
            voice_id = m.get("canonical_name")
            if not voice_id or voice_id in seen:
                continue
            seen.add(voice_id)
            arch = m.get("architecture") or ""
            langs = m.get("languages") or []
            meta = m.get("metadata") or {}
            family, arch_rank = (
                ("Flux", 0) if _is_flux(voice_id)
                else ("Aura 2", 1) if arch == "aura-2"
                else ("Aura", 2)
            )
            description = " · ".join(p for p in [
                family,
                ", ".join(langs),
                meta.get("accent"),
                ", ".join((meta.get("tags") or [])[:3]),
            ] if p)
            rank = (0 if any(l.startswith("en") for l in langs) else 1, arch_rank)
            out.append({
                "id": voice_id,
                "name": (meta.get("display_name") or m.get("name") or voice_id).title(),
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

        model = voice_id or self.DEFAULT_VOICE
        params: dict = {"model": model, "encoding": "mp3"}
        speed = float(voice_settings.get("speed", 1.0))
        if speed != 1.0:
            params["speed"] = speed
        # Flux-only, beta: integer -2 (calm) … 2 (animated); 0 is the
        # voice's tuned default, so leave it off the request.
        expressivity = int(voice_settings.get("expressivity", 0)) if _is_flux(model) else 0
        if expressivity:
            params["expressivity"] = max(-2, min(2, expressivity))
        path = "/v2/speak" if _is_flux(model) else "/v1/speak"
        headers = {"Authorization": f"Token {key}"}

        logger.info(
            "Deepgram TTS: voice=%s, speed=%.2f, expressivity=%d, %d chars",
            model, speed, expressivity, len(text),
        )

        # MP3 frames concatenate cleanly, so long text is synthesized per
        # chunk and joined.
        audio = b""
        for chunk in _split_text(text):
            resp = await _http().post(path, params=params, headers=headers, json={"text": chunk})
            if resp.status_code != 200:
                logger.error(
                    "Deepgram TTS error: status=%d, voice=%s, chars=%d, body=%s",
                    resp.status_code, params["model"], len(chunk), resp.text[:500],
                )
                resp.raise_for_status()
            audio += resp.content
        return audio
