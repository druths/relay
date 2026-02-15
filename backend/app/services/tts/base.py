"""Base class for TTS providers."""

from __future__ import annotations

from abc import ABC, abstractmethod


class TTSProvider(ABC):
    @abstractmethod
    async def synthesize(self, text: str, voice_id: str, settings: dict) -> bytes:
        """Synthesize text to audio.

        Args:
            text: The text to speak.
            voice_id: Provider-specific voice identifier.
            settings: Provider-specific settings (speed, etc.).

        Returns:
            MP3 audio bytes.
        """
        ...

    @classmethod
    @abstractmethod
    def available_voices(cls) -> list[dict]:
        """Return available voices for this provider.

        Returns:
            List of dicts with keys: id, name, description.
        """
        ...
