"""OpenAI Whisper STT provider."""

from __future__ import annotations

import io
import logging

from openai import AsyncOpenAI

from app.config import settings
from app.services.stt.base import STTProvider

logger = logging.getLogger(__name__)

_clients: dict[str, AsyncOpenAI] = {}


def _get_client(api_key: str | None = None) -> AsyncOpenAI | None:
    effective_key = api_key or settings.openai_api_key
    if not effective_key:
        return None
    if effective_key not in _clients:
        _clients[effective_key] = AsyncOpenAI(api_key=effective_key)
    return _clients[effective_key]


class OpenAISTTProvider(STTProvider):
    def __init__(self, api_key: str | None = None):
        self._api_key = api_key

    # Whisper hallucinates these phrases on silence/noise
    HALLUCINATION_BLOCKLIST = {
        "thank you",
        "thank you.",
        "thanks.",
        "thanks for watching.",
        "thank you for watching.",
        "thank you for watching!",
        "thank you very much.",
        "thanks for watching!",
        "subscribe",
        "bye.",
        "bye!",
        "bye-bye.",
        "you",
        "the end",
        "the end.",
    }

    async def transcribe(
        self,
        audio_bytes: bytes,
        format: str = "webm",
        no_speech_threshold: float = 0.5,
    ) -> str:
        client = _get_client(self._api_key)
        if client is None:
            raise RuntimeError("OpenAI API key not configured")

        logger.info("OpenAI STT: %d bytes, format=%s, no_speech_threshold=%.2f",
                     len(audio_bytes), format, no_speech_threshold)

        audio_file = io.BytesIO(audio_bytes)
        audio_file.name = f"audio.{format}"

        transcript = await client.audio.transcriptions.create(
            model="whisper-1",
            file=audio_file,
            response_format="verbose_json",
            timestamp_granularities=["segment"],
        )

        # NOTE: segments are TranscriptionSegment objects, not dicts — use attribute access
        segments = getattr(transcript, "segments", None) or []
        kept = []
        for seg in segments:
            prob = getattr(seg, "no_speech_prob", 0) or 0
            seg_text = getattr(seg, "text", "") or ""
            logger.info(
                "OpenAI STT segment: no_speech_prob=%.3f, text=%r",
                prob, seg_text[:80],
            )
            if prob >= no_speech_threshold:
                logger.info("OpenAI STT: filtered (no_speech_prob >= %.2f)", no_speech_threshold)
                continue
            if seg_text.strip().lower() in self.HALLUCINATION_BLOCKLIST:
                logger.info("OpenAI STT: filtered hallucination %r", seg_text.strip())
                continue
            kept.append(seg_text)

        text = " ".join(kept).strip() if kept else ""

        if text:
            logger.info("OpenAI STT result: %d chars — %r", len(text), text[:120])
        else:
            logger.info("OpenAI STT: no usable speech detected")

        return text
