"""Ark LLM provider — talks to a self-hosted ark agent harness.

Ark hosts multiple named agents on a single HTTP+WebSocket server. Each
conversation is a server-owned `session` with persisted history. Relay maps
one Relay session 1:1 to one ark session; the ark session_id is persisted in
`sessions.provider_state['ark']` via the agent_manager.

Per-turn flow:
  1. Create ark session via REST if we don't already have one for this Relay session
  2. Open WS to /agents/<name>/sessions/<ark_session_id>
  3. Send {"type":"user_message", "text": <last user message>}
  4. Stream assistant_delta events as text
  5. Close WS on `done`, return the (possibly-new) ark session_id for persistence

Cancellation: if the async generator is cancelled (caller calls task.cancel()),
we send {"type":"stop"} to ark and close the socket cleanly. This maps to ark's
documented stop semantics.
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from typing import Any

import httpx
import websockets

from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)


def _agent_name(model: str) -> str:
    """Extract the ark agent name from an optional 'ark:<name>' prefix."""
    if model.startswith("ark:"):
        return model[len("ark:"):]
    return model


def _last_user_text(messages: list[dict[str, Any]]) -> str:
    """Ark owns history server-side, so we only need to send the most recent
    user message on each turn."""
    for m in reversed(messages):
        if m.get("role") == "user":
            return m.get("content", "") or ""
    return ""


@dataclass
class ArkResult:
    """Final yield from a streaming generation — carries the ark session_id
    so the caller can persist it for the next turn's chain."""
    text: str
    session_id: str | None = None


class ArkProvider(LLMProvider):
    def __init__(self, base_url: str, api_key: str | None = None):
        # Strip trailing slash and remember the parts we need to build URLs.
        self._base_http = base_url.rstrip("/")
        self._base_ws = self._base_http.replace("http://", "ws://", 1).replace("https://", "wss://", 1)
        self._api_key = api_key

    # ── LLMProvider interface ────────────────────────────────────────

    async def generate(self, system_prompt, messages, model):
        result = await self.generate_with_chain(system_prompt, messages, model)
        return result.text

    async def generate_stream(self, system_prompt, messages, model):
        async for chunk in self.generate_stream_with_chain(system_prompt, messages, model):
            if isinstance(chunk, str):
                yield chunk

    # ── Chain-aware variants — return/yield ArkResult with session_id ──

    async def generate_with_chain(
        self,
        system_prompt,
        messages,
        model,
        previous_session_id: str | None = None,
    ) -> ArkResult:
        chunks: list[str] = []
        final_session_id: str | None = None
        async for item in self.generate_stream_with_chain(
            system_prompt, messages, model, previous_session_id=previous_session_id,
        ):
            if isinstance(item, str):
                chunks.append(item)
            elif isinstance(item, ArkResult):
                final_session_id = item.session_id
        return ArkResult(text="".join(chunks), session_id=final_session_id)

    async def generate_stream_with_chain(
        self,
        system_prompt,  # currently unused — ark agents own their own system prompts
        messages,
        model,
        previous_session_id: str | None = None,
    ):
        agent = _agent_name(model)
        user_text = _last_user_text(messages)
        logger.info(
            "Ark stream: agent=%s, chain=%s, %d chars",
            agent, previous_session_id is not None, len(user_text),
        )

        session_id = previous_session_id or await self._ensure_session(agent)
        ws_url = f"{self._base_ws}/agents/{agent}/sessions/{session_id}"

        headers = {"Authorization": f"Bearer {self._api_key}"} if self._api_key else None
        ws = await websockets.connect(ws_url, additional_headers=headers, max_size=None)

        try:
            await ws.send(json.dumps({"type": "user_message", "text": user_text}))
            async for raw in ws:
                try:
                    event = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                etype = event.get("type")
                if etype == "assistant_delta":
                    delta = event.get("text") or event.get("delta") or ""
                    if delta:
                        yield delta
                elif etype == "error":
                    logger.warning("Ark error event: %s", event.get("message"))
                elif etype == "done":
                    break
                # tool_call / tool_result / thinking / assistant_message are
                # intentionally filtered — the user-facing text is the
                # accumulation of assistant_delta events.
        except asyncio.CancelledError:
            # Cooperative cancellation: tell ark to stop, then re-raise so the
            # surrounding task unwinds normally. Best-effort — ignore send failures.
            try:
                await asyncio.wait_for(
                    ws.send(json.dumps({"type": "stop"})), timeout=0.5,
                )
            except Exception:
                pass
            raise
        finally:
            try:
                await ws.close()
            except Exception:
                pass

        # Always yield the result at the end so the caller can persist the
        # ark session_id for chaining the next turn.
        yield ArkResult(text="", session_id=session_id)

    # ── Helpers ─────────────────────────────────────────────────────

    async def _ensure_session(self, agent: str) -> str:
        """Create a new ark session and return its id."""
        url = f"{self._base_http}/agents/{agent}/sessions"
        headers = {"Authorization": f"Bearer {self._api_key}"} if self._api_key else {}
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, headers=headers, json={})
            resp.raise_for_status()
            data = resp.json()
            session_id = data.get("id") or data.get("session_id")
            if not session_id:
                raise RuntimeError(f"Ark session creation returned no id: {data}")
            logger.info("Ark session created: agent=%s session=%s", agent, session_id)
            return session_id
