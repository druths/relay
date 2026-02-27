"""OpenClaw LLM provider — talks to an OpenClaw gateway via its OpenAI-compatible API."""

from __future__ import annotations

import logging

from openai import AsyncOpenAI

from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)

# Cache clients by (api_key, base_url) tuple
_clients: dict[tuple[str | None, str], AsyncOpenAI] = {}


def _get_client(base_url: str, api_key: str | None = None) -> AsyncOpenAI:
    """Return a cached AsyncOpenAI client pointed at the OpenClaw gateway."""
    effective_url = base_url.rstrip("/")
    if not effective_url.endswith("/v1"):
        effective_url += "/v1"

    cache_key = (api_key, effective_url)
    if cache_key not in _clients:
        _clients[cache_key] = AsyncOpenAI(
            api_key=api_key or "not-needed",
            base_url=effective_url,
        )
    return _clients[cache_key]


class OpenClawProvider(LLMProvider):
    def __init__(self, base_url: str, api_key: str | None = None):
        self._base_url = base_url
        self._api_key = api_key

    @staticmethod
    def _model_name(agent_id: str) -> str:
        """Ensure the model field uses the ``openclaw:<agentId>`` format."""
        if agent_id.startswith("openclaw:"):
            return agent_id
        return f"openclaw:{agent_id}"

    async def generate(self, system_prompt, messages, model):
        client = _get_client(self._base_url, self._api_key)
        oc_model = self._model_name(model)

        llm_messages = [{"role": "system", "content": system_prompt}]
        llm_messages.extend(messages)

        logger.info("OpenClaw generate: gateway=%s agent=%s, %d messages",
                     self._base_url, oc_model, len(llm_messages))

        response = await client.chat.completions.create(
            model=oc_model,
            messages=llm_messages,
        )
        return response.choices[0].message.content or ""

    async def generate_stream(self, system_prompt, messages, model):
        client = _get_client(self._base_url, self._api_key)
        oc_model = self._model_name(model)

        llm_messages = [{"role": "system", "content": system_prompt}]
        llm_messages.extend(messages)

        logger.info("OpenClaw stream: gateway=%s agent=%s, %d messages",
                     self._base_url, oc_model, len(llm_messages))

        response = await client.chat.completions.create(
            model=oc_model,
            messages=llm_messages,
            stream=True,
        )
        async for chunk in response:
            delta = chunk.choices[0].delta.content
            if delta:
                yield delta
