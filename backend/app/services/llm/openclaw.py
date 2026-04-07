"""OpenClaw LLM provider — uses the /v1/responses endpoint for clean output (no think/action blocks)."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
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


def _last_user_input(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Extract only the last user message for chained requests."""
    for m in reversed(messages):
        if m["role"] == "user":
            return [{"type": "message", "role": "user", "content": m["content"]}]
    return _build_input(messages)


@dataclass
class OpenClawResult:
    """Result from an OpenClaw call, including the response ID for chaining."""
    text: str
    response_id: str | None = None


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
        result = await self.generate_with_chain(system_prompt, messages, model)
        return result.text

    async def generate_with_chain(
        self,
        system_prompt,
        messages,
        model,
        previous_response_id: str | None = None,
    ) -> OpenClawResult:
        agent_id = _agent_id(model)
        logger.info(
            "OpenClaw generate: agent=%s, %d messages, chain=%s",
            agent_id, len(messages), previous_response_id is not None,
        )

        if previous_response_id:
            input_items = _last_user_input(messages)
        else:
            input_items = _build_input(messages)

        payload: dict[str, Any] = {
            "model": "openclaw",
            "input": input_items,
        }
        if system_prompt and not previous_response_id:
            payload["instructions"] = system_prompt
        if previous_response_id:
            payload["previous_response_id"] = previous_response_id

        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(self._responses_url, headers=self._headers(agent_id), json=payload)
            resp.raise_for_status()
            data = resp.json()

            response_id = data.get("id")
            text = ""
            for item in data.get("output", []):
                if item.get("type") == "message":
                    for part in item.get("content", []):
                        if part.get("type") == "output_text":
                            text = part.get("text", "")

            return OpenClawResult(text=text, response_id=response_id)

    async def generate_stream(self, system_prompt, messages, model):
        async for chunk in self.generate_stream_with_chain(system_prompt, messages, model):
            if isinstance(chunk, str):
                yield chunk

    async def generate_stream_with_chain(
        self,
        system_prompt,
        messages,
        model,
        previous_response_id: str | None = None,
    ):
        """Stream response, yielding text deltas. The final yield is an OpenClawResult with the response_id."""
        agent_id = _agent_id(model)
        logger.info(
            "OpenClaw stream: agent=%s, %d messages, chain=%s",
            agent_id, len(messages), previous_response_id is not None,
        )

        if previous_response_id:
            input_items = _last_user_input(messages)
        else:
            input_items = _build_input(messages)

        payload: dict[str, Any] = {
            "model": "openclaw",
            "input": input_items,
            "stream": True,
        }
        if system_prompt and not previous_response_id:
            payload["instructions"] = system_prompt
        if previous_response_id:
            payload["previous_response_id"] = previous_response_id

        response_id: str | None = None

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

                    # Capture the response ID from the response.created event
                    if event.get("type") == "response.created":
                        response_id = event.get("response", {}).get("id")
                    elif event.get("type") == "response.output_text.delta":
                        delta = event.get("delta", "")
                        if delta:
                            yield delta

        # Final yield: the result with response_id for the caller to store
        yield OpenClawResult(text="", response_id=response_id)
