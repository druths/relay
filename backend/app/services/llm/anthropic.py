"""Anthropic LLM provider."""

from __future__ import annotations

import logging

from anthropic import AsyncAnthropic

from app.config import settings
from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)

_client: AsyncAnthropic | None = None


def _get_client() -> AsyncAnthropic | None:
    global _client
    if not settings.anthropic_api_key:
        return None
    if _client is None:
        _client = AsyncAnthropic(api_key=settings.anthropic_api_key)
    return _client


def _ensure_alternation(messages: list[dict]) -> list[dict]:
    """Merge consecutive same-role messages (Anthropic requires strict alternation)."""
    if not messages:
        return messages

    merged: list[dict] = [messages[0].copy()]
    for msg in messages[1:]:
        if msg["role"] == merged[-1]["role"]:
            merged[-1]["content"] += "\n" + msg["content"]
        else:
            merged.append(msg.copy())

    # Anthropic requires first message to be "user"
    if merged and merged[0]["role"] != "user":
        merged.insert(0, {"role": "user", "content": "(conversation start)"})

    return merged


class AnthropicProvider(LLMProvider):
    async def generate(
        self,
        system_prompt: str,
        messages: list[dict],
        model: str,
    ) -> str:
        client = _get_client()
        if client is None:
            raise RuntimeError("Anthropic API key not configured")

        clean_messages = _ensure_alternation(messages)

        logger.info("Anthropic generate: model=%s, %d messages", model, len(clean_messages))

        response = await client.messages.create(
            model=model,
            system=system_prompt,
            messages=clean_messages,
            max_tokens=1024,
        )

        return response.content[0].text

    async def generate_stream(self, system_prompt, messages, model):
        client = _get_client()
        if client is None:
            raise RuntimeError("Anthropic API key not configured")

        clean_messages = _ensure_alternation(messages)

        logger.info("Anthropic stream: model=%s, %d messages", model, len(clean_messages))

        async with client.messages.stream(
            model=model,
            system=system_prompt,
            messages=clean_messages,
            max_tokens=1024,
        ) as stream:
            async for text in stream.text_stream:
                yield text
