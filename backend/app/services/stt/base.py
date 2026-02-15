"""Base class for STT providers."""

from __future__ import annotations

from abc import ABC, abstractmethod


class STTProvider(ABC):
    @abstractmethod
    async def transcribe(self, audio_bytes: bytes, format: str = "webm") -> str:
        """Transcribe audio to text.

        Args:
            audio_bytes: Raw audio file bytes.
            format: Audio format (webm, mp3, wav, etc.).

        Returns:
            Transcribed text string.
        """
        ...
