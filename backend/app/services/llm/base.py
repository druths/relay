"""Base class for LLM providers."""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import AsyncGenerator


class LLMProvider(ABC):
    @abstractmethod
    async def generate(
        self,
        system_prompt: str,
        messages: list[dict],
        model: str,
        *,
        extra_body: dict | None = None,
    ) -> str:
        """Generate a response.

        Args:
            system_prompt: The agent's persona/system prompt.
            messages: Conversation history as [{"role": "user"/"assistant", "content": "..."}].
            model: The model identifier (e.g. "gpt-4o-mini", "claude-sonnet-4-5-20250929").
            extra_body: Extra request fields for OpenAI-compatible endpoints
                (e.g. OpenRouter's `provider` routing). Others ignore it.

        Returns:
            The assistant's response text.
        """
        ...

    async def generate_stream(
        self,
        system_prompt: str,
        messages: list[dict],
        model: str,
        *,
        extra_body: dict | None = None,
    ) -> AsyncGenerator[str, None]:
        """Yield response tokens as they arrive. Default: falls back to generate()."""
        kwargs = {"extra_body": extra_body} if extra_body else {}
        result = await self.generate(system_prompt, messages, model, **kwargs)
        yield result
