"""OpenAI Whisper STT provider."""

from __future__ import annotations

import io
import logging

from openai import AsyncOpenAI

from app.config import settings
from app.services.stt.base import STTProvider

logger = logging.getLogger(__name__)

_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI | None:
    global _client
    if not settings.openai_api_key:
        return None
    if _client is None:
        _client = AsyncOpenAI(api_key=settings.openai_api_key)
    return _client


class OpenAISTTProvider(STTProvider):
    NO_SPEECH_THRESHOLD = 0.5

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

    async def transcribe(self, audio_bytes: bytes, format: str = "webm") -> str:
        client = _get_client()
        if client is None:
            raise RuntimeError("OpenAI API key not configured")

        logger.info("OpenAI STT: %d bytes, format=%s", len(audio_bytes), format)

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
            if prob >= self.NO_SPEECH_THRESHOLD:
                logger.info("OpenAI STT: filtered (no_speech_prob >= %.1f)", self.NO_SPEECH_THRESHOLD)
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
