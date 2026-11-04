"""Base class for TTS providers."""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import AsyncIterator


class TTSStream(ABC):
    """One reply's speech over a provider's streaming connection: text goes
    in as it's produced, raw 16-bit mono PCM comes out as it's generated."""

    sample_rate: int

    @abstractmethod
    async def send(self, text: str) -> None:
        """Queue more text for synthesis."""

    @abstractmethod
    async def finish(self) -> None:
        """No more text is coming; synthesize whatever is still queued."""

    @abstractmethod
    def audio(self) -> AsyncIterator[bytes]:
        """PCM as it's generated, ending once everything sent before
        `finish()` has been spoken."""

    @abstractmethod
    async def aclose(self) -> None:
        ...


class TTSProvider(ABC):
    async def open_stream(self, voice_id: str, settings: dict) -> TTSStream | None:
        """Open a streaming connection for one reply, or None when the
        provider only does whole-text synthesis."""
        return None

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
