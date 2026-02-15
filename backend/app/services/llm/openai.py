"""OpenAI LLM provider. Also handles Ollama and other OpenAI-compatible APIs via base_url."""

from __future__ import annotations

import logging

from openai import AsyncOpenAI

from app.config import settings
from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)

# Cache clients by base_url so Ollama gets a separate instance
_clients: dict[str | None, AsyncOpenAI] = {}


def _get_client(base_url: str | None = None) -> AsyncOpenAI | None:
    if base_url not in _clients:
        if base_url:
            # Custom endpoint (Ollama, OpenClaw, etc.) — no API key needed
            _clients[base_url] = AsyncOpenAI(
                api_key=settings.openai_api_key or "not-needed",
                base_url=base_url,
            )
        else:
            if not settings.openai_api_key:
                return None
            _clients[None] = AsyncOpenAI(api_key=settings.openai_api_key)
    return _clients[base_url]


class OpenAIProvider(LLMProvider):
    def __init__(self, base_url: str | None = None):
        self._base_url = base_url

    async def generate(
        self,
        system_prompt: str,
        messages: list[dict],
        model: str,
    ) -> str:
        client = _get_client(self._base_url)
        if client is None:
            raise RuntimeError("OpenAI API key not configured")

        llm_messages = [{"role": "system", "content": system_prompt}]
        llm_messages.extend(messages)

        logger.info("OpenAI generate: model=%s, %d messages", model, len(llm_messages))

        response = await client.chat.completions.create(
            model=model,
            messages=llm_messages,
        )

        return response.choices[0].message.content or ""

    async def generate_stream(self, system_prompt, messages, model):
        client = _get_client(self._base_url)
        if client is None:
            raise RuntimeError("OpenAI API key not configured")

        llm_messages = [{"role": "system", "content": system_prompt}]
        llm_messages.extend(messages)

        logger.info("OpenAI stream: model=%s, %d messages", model, len(llm_messages))

        response = await client.chat.completions.create(
            model=model,
            messages=llm_messages,
            stream=True,
        )
        async for chunk in response:
            delta = chunk.choices[0].delta.content
            if delta:
                yield delta
