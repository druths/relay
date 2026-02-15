"""Google Gemini LLM provider."""

from __future__ import annotations

import logging

from google import genai
from google.genai import types

from app.config import settings
from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)

_client: genai.Client | None = None


def _get_client() -> genai.Client | None:
    global _client
    if not settings.gemini_api_key:
        return None
    if _client is None:
        _client = genai.Client(api_key=settings.gemini_api_key)
    return _client


class GeminiProvider(LLMProvider):
    def _build_contents(self, messages: list[dict]) -> list[types.Content]:
        """Convert messages to Gemini format (uses 'model' instead of 'assistant')."""
        contents = []
        for msg in messages:
            role = "model" if msg["role"] == "assistant" else msg["role"]
            contents.append(types.Content(
                role=role,
                parts=[types.Part.from_text(text=msg["content"])],
            ))
        return contents

    async def generate(
        self,
        system_prompt: str,
        messages: list[dict],
        model: str,
    ) -> str:
        client = _get_client()
        if client is None:
            raise RuntimeError("Gemini API key not configured")

        contents = self._build_contents(messages)

        logger.info("Gemini generate: model=%s, %d messages", model, len(contents))

        response = await client.aio.models.generate_content(
            model=model,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
            ),
        )

        return response.text or ""

    async def generate_stream(self, system_prompt, messages, model):
        client = _get_client()
        if client is None:
            raise RuntimeError("Gemini API key not configured")

        contents = self._build_contents(messages)

        logger.info("Gemini stream: model=%s, %d messages", model, len(contents))

        async for chunk in await client.aio.models.generate_content_stream(
            model=model,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
            ),
        ):
            if chunk.text:
                yield chunk.text
