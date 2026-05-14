"""Ark LLM provider — talks to a self-hosted ark agent harness over a
long-lived WebSocket per Relay session.

Ark hosts multiple named agents on a single HTTP+WebSocket server. Each
conversation is a server-owned `session` with persisted history. Relay maps
one Relay session 1:1 to one ark session; the ark session_id is persisted in
`sessions.provider_state['ark']` via the agent_manager.

Connection model
────────────────
We hold one hot WebSocket per Relay session for as long as the session is
active. A single consumer task reads frames off the socket and dispatches
them to one of two sinks:

  • turn-scoped events (assistant_delta, tool_call, tool_result, thinking,
    assistant_message, done, error) → the current turn's queue, drained by
    `generate_stream_with_chain`.
  • async events (file_available, injected_message) → an out-of-band
    callback registered by the agent_manager wiring, used to push
    notifications into the Relay client's WS even when no turn is in flight.

Connections survive Relay client disconnects (e.g. the user backgrounds the
app), and are torn down on session_left / session_deleted / backend shutdown.
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

import httpx
import websockets

from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)


# Events that belong to an active turn — drained by the streaming generator.
TURN_EVENT_TYPES = {
    "assistant_delta", "tool_call", "tool_result", "thinking",
    "assistant_message", "done", "error",
}

# Events that arrive out-of-band — surfaced via the async callback.
ASYNC_EVENT_TYPES = {"file_available", "injected_message"}


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


# Type alias for the async-event callback. Takes the raw event dict.
AsyncEventCallback = Callable[[dict[str, Any]], Awaitable[None]]


class ArkSessionConnection:
    """One long-lived WS to ark for a single Relay session.

    Created lazily on the first turn; lives until the Relay session is
    explicitly closed. Recovers from transient WS drops by reconnecting on
    the same ark session_id (ark continues the session server-side).
    """

    def __init__(
        self,
        base_http: str,
        base_ws: str,
        agent: str,
        session_id: str,
        api_key: str | None,
    ):
        self.base_http = base_http
        self.base_ws = base_ws
        self.agent = agent
        self.session_id = session_id
        self.api_key = api_key

        self._ws: websockets.ClientConnection | None = None
        self._consumer: asyncio.Task | None = None
        # The queue is set by start_turn() and cleared by end_turn(). Only
        # one turn is in flight at a time per Relay session.
        self._turn_queue: asyncio.Queue[dict] | None = None
        self._closed = False
        self._async_callback: AsyncEventCallback | None = None
        # Lock around start_turn / end_turn so concurrent calls can't
        # interleave queues.
        self._turn_lock = asyncio.Lock()

    # ── Public lifecycle ────────────────────────────────────────────

    def set_async_callback(self, cb: AsyncEventCallback | None) -> None:
        """Register the callback that receives file_available, injected_message,
        etc. Pass None to detach. Safe to call from any task."""
        self._async_callback = cb

    async def ensure_connected(self) -> None:
        """Open the WS if not already; idempotent."""
        if self._ws is not None and not self._closed:
            return
        await self._connect()

    async def close(self) -> None:
        """Shut down the connection permanently. Cancels the consumer and
        breaks any in-flight turn queue."""
        self._closed = True
        if self._consumer:
            self._consumer.cancel()
            try:
                await self._consumer
            except (asyncio.CancelledError, Exception):
                pass
            self._consumer = None
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None
        # Unblock any waiting turn consumer with a sentinel.
        if self._turn_queue:
            await self._turn_queue.put({"type": "done", "_closed": True})

    # ── Turn API ────────────────────────────────────────────────────

    async def send_user_message(self, text: str) -> None:
        """Send a user_message frame and prepare the turn queue. Caller is
        responsible for then calling `iter_turn_events()` to drain it."""
        await self.ensure_connected()
        async with self._turn_lock:
            self._turn_queue = asyncio.Queue()
        assert self._ws is not None
        await self._ws.send(json.dumps({"type": "user_message", "text": text}))

    async def iter_turn_events(self):
        """Yield turn events until a `done` is observed."""
        if self._turn_queue is None:
            return
        try:
            while True:
                event = await self._turn_queue.get()
                yield event
                if event.get("type") == "done":
                    break
        finally:
            self._turn_queue = None

    async def send_stop(self) -> None:
        """Best-effort cancel of the in-flight turn."""
        if self._ws is None:
            return
        try:
            await asyncio.wait_for(
                self._ws.send(json.dumps({"type": "stop"})),
                timeout=0.5,
            )
        except Exception:
            pass

    # ── Internals ───────────────────────────────────────────────────

    async def _connect(self) -> None:
        url = f"{self.base_ws}/agents/{self.agent}/sessions/{self.session_id}"
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else None
        self._ws = await websockets.connect(url, additional_headers=headers, max_size=None)
        self._consumer = asyncio.create_task(self._consume(), name=f"ark-consumer-{self.session_id}")
        logger.info("Ark WS connected: agent=%s session=%s", self.agent, self.session_id)

    async def _consume(self) -> None:
        """Read frames forever, dispatch to turn queue or async callback.
        Reconnects on drop with exponential backoff until `close()` is called."""
        backoff = 1.0
        while not self._closed:
            assert self._ws is not None
            try:
                async for raw in self._ws:
                    try:
                        event = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    etype = event.get("type")
                    if etype in TURN_EVENT_TYPES and self._turn_queue is not None:
                        await self._turn_queue.put(event)
                    elif etype in ASYNC_EVENT_TYPES:
                        if self._async_callback:
                            try:
                                await self._async_callback(event)
                            except Exception:
                                logger.exception("Ark async callback failed for event %s", etype)
                    # else: ignore unknown / orphaned events
                # Stream ended cleanly.
                if self._closed:
                    return
                logger.warning("Ark WS closed by server, reconnecting…")
            except websockets.ConnectionClosed:
                if self._closed:
                    return
                logger.warning("Ark WS connection closed, reconnecting…")
            except Exception:
                logger.exception("Ark WS consumer error, reconnecting…")
            # Drop any in-flight turn — caller will surface the failure.
            if self._turn_queue is not None:
                await self._turn_queue.put({
                    "type": "error", "message": "Ark WS dropped mid-turn",
                })
            self._ws = None
            # Backoff before reconnect.
            await asyncio.sleep(min(backoff, 30.0))
            try:
                await self._connect()
                backoff = 1.0
            except Exception:
                logger.exception("Ark WS reconnect failed; backing off")
                backoff = min(backoff * 2.0, 30.0)


# Global registry of live connections, keyed by Relay session_id.
_connections: dict[str, ArkSessionConnection] = {}
_registry_lock = asyncio.Lock()


async def get_or_create_connection(
    *,
    base_http: str,
    base_ws: str,
    agent: str,
    relay_session_id: str,
    ark_session_id: str,
    api_key: str | None,
) -> ArkSessionConnection:
    """Look up the live ark connection for a Relay session, or open one.

    Connections are keyed by Relay session id (not ark session id) so we can
    find them again when async events need to fan out to a Relay client.
    """
    async with _registry_lock:
        conn = _connections.get(relay_session_id)
        if conn is not None and not conn._closed:
            return conn
        conn = ArkSessionConnection(
            base_http=base_http,
            base_ws=base_ws,
            agent=agent,
            session_id=ark_session_id,
            api_key=api_key,
        )
        _connections[relay_session_id] = conn
        await conn.ensure_connected()
        return conn


async def close_connection(relay_session_id: str) -> None:
    """Tear down the ark connection for a Relay session, if any."""
    async with _registry_lock:
        conn = _connections.pop(relay_session_id, None)
    if conn is not None:
        await conn.close()


async def close_all_connections() -> None:
    """Backend-shutdown hook."""
    async with _registry_lock:
        conns = list(_connections.values())
        _connections.clear()
    for c in conns:
        try:
            await c.close()
        except Exception:
            pass


def get_connection(relay_session_id: str) -> ArkSessionConnection | None:
    """Synchronous lookup for callers that need to register an async callback."""
    return _connections.get(relay_session_id)


# ── LLMProvider ────────────────────────────────────────────────────


class ArkProvider(LLMProvider):
    def __init__(self, base_url: str, api_key: str | None = None):
        base = base_url.rstrip("/")
        self._base_http = base
        self._base_ws = base.replace("http://", "ws://", 1).replace("https://", "wss://", 1)
        self._api_key = api_key

    # ── LLMProvider interface ────────────────────────────────────────

    async def generate(self, system_prompt, messages, model):
        result = await self.generate_with_chain(system_prompt, messages, model)
        return result.text

    async def generate_stream(self, system_prompt, messages, model):
        async for chunk in self.generate_stream_with_chain(system_prompt, messages, model):
            if isinstance(chunk, str):
                yield chunk

    # ── Chain-aware variants ────────────────────────────────────────

    async def generate_with_chain(
        self,
        system_prompt,
        messages,
        model,
        relay_session_id: str | None = None,
        previous_session_id: str | None = None,
    ) -> ArkResult:
        chunks: list[str] = []
        final_session_id: str | None = None
        async for item in self.generate_stream_with_chain(
            system_prompt, messages, model,
            relay_session_id=relay_session_id,
            previous_session_id=previous_session_id,
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
        relay_session_id: str | None = None,
        previous_session_id: str | None = None,
    ):
        agent = _agent_name(model)
        user_text = _last_user_text(messages)
        logger.info(
            "Ark stream: agent=%s, chain=%s, %d chars",
            agent, previous_session_id is not None, len(user_text),
        )

        ark_session_id = previous_session_id or await self._ensure_session(agent)

        # Resolve the long-lived connection. If we don't have a Relay session
        # context (e.g. called from outside a session), open a one-shot
        # connection scoped to this call.
        if relay_session_id:
            conn = await get_or_create_connection(
                base_http=self._base_http,
                base_ws=self._base_ws,
                agent=agent,
                relay_session_id=relay_session_id,
                ark_session_id=ark_session_id,
                api_key=self._api_key,
            )
            owned = False
        else:
            conn = ArkSessionConnection(
                base_http=self._base_http,
                base_ws=self._base_ws,
                agent=agent,
                session_id=ark_session_id,
                api_key=self._api_key,
            )
            await conn.ensure_connected()
            owned = True

        try:
            await conn.send_user_message(user_text)
            try:
                async for event in conn.iter_turn_events():
                    etype = event.get("type")
                    if etype == "assistant_delta":
                        delta = event.get("text") or event.get("delta") or ""
                        if delta:
                            yield delta
                    elif etype == "error":
                        logger.warning("Ark error event: %s", event.get("message"))
                    elif etype == "done":
                        break
                    # tool_call / tool_result / thinking / assistant_message
                    # are intentionally filtered.
            except asyncio.CancelledError:
                await conn.send_stop()
                raise
        finally:
            if owned:
                await conn.close()

        yield ArkResult(text="", session_id=ark_session_id)

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
