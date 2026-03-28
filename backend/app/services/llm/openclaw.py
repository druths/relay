"""OpenClaw LLM provider — uses the /v1/responses endpoint for clean output (no think/action blocks)."""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx

from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)


def _agent_id(model: str) -> str:
    """Extract the bare agent ID from an optional 'openclaw:<id>' prefix."""
    if model.startswith("openclaw:"):
        return model[len("openclaw:"):]
    return model


def _build_input(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Convert Chat Completions message dicts to Responses API input items."""
    return [{"type": "message", "role": m["role"], "content": m["content"]} for m in messages]


class OpenClawProvider(LLMProvider):
    def __init__(self, base_url: str, api_key: str | None = None):
        base = base_url.rstrip("/")
        # Responses API lives at /v1/responses (not /v1/chat/completions)
        self._responses_url = f"{base}/v1/responses"
        self._api_key = api_key

    def _headers(self, agent_id: str) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._api_key or 'not-needed'}",
            "Content-Type": "application/json",
            "x-openclaw-agent-id": agent_id,
        }

    async def generate(self, system_prompt, messages, model):
        agent_id = _agent_id(model)
        logger.info("OpenClaw generate: agent=%s, %d messages", agent_id, len(messages))

        payload: dict[str, Any] = {
            "model": "openclaw",
            "input": _build_input(messages),
        }
        if system_prompt:
            payload["instructions"] = system_prompt

        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(self._responses_url, headers=self._headers(agent_id), json=payload)
            resp.raise_for_status()
            data = resp.json()
            # Extract text from output items
            for item in data.get("output", []):
                if item.get("type") == "message":
                    for part in item.get("content", []):
                        if part.get("type") == "output_text":
                            return part.get("text", "")
            return ""

    async def generate_stream(self, system_prompt, messages, model):
        agent_id = _agent_id(model)
        logger.info("OpenClaw stream: agent=%s, %d messages", agent_id, len(messages))

        payload: dict[str, Any] = {
            "model": "openclaw",
            "input": _build_input(messages),
            "stream": True,
        }
        if system_prompt:
            payload["instructions"] = system_prompt

        async with httpx.AsyncClient(timeout=120) as client:
            async with client.stream(
                "POST", self._responses_url,
                headers=self._headers(agent_id),
                json=payload,
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        event = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue
                    if event.get("type") == "response.output_text.delta":
                        delta = event.get("delta", "")
                        if delta:
                            yield delta
