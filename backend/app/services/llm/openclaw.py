"""OpenClaw LLM provider — talks to an OpenClaw gateway via its OpenAI-compatible API."""

from __future__ import annotations

import logging
import re

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


_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)
_OPEN_TAG = "<think>"
_CLOSE_TAG = "</think>"


def _strip_thinking(text: str) -> str:
    return _THINK_RE.sub("", text).strip()


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
        return _strip_thinking(response.choices[0].message.content or "")

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
        buf = ""
        in_think = False
        async for chunk in response:
            delta = chunk.choices[0].delta.content
            if not delta:
                continue
            buf += delta
            while True:
                if in_think:
                    end = buf.find(_CLOSE_TAG)
                    if end >= 0:
                        buf = buf[end + len(_CLOSE_TAG):]
                        in_think = False
                    else:
                        buf = ""
                        break
                else:
                    start = buf.find(_OPEN_TAG)
                    if start >= 0:
                        if start > 0:
                            yield buf[:start]
                        buf = buf[start + len(_OPEN_TAG):]
                        in_think = True
                    else:
                        # Hold back enough chars to detect a tag spanning a chunk boundary
                        hold = len(_OPEN_TAG) - 1
                        if len(buf) > hold:
                            yield buf[:-hold]
                            buf = buf[-hold:]
                        break
        if buf and not in_think:
            yield buf
