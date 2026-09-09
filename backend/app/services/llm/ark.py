"""Ark LLM provider — talks to a self-hosted ark agent harness over a single
per-server, per-(base_url, api_key) WebSocket connection.

Ark's unified event stream (`WS /events`, see ark/CHANGELOG.md) carries
events for *every* session the connection's token is authorized to see. One
connection per ark server is therefore enough — turns, async injections,
file shares, heartbeat/cron output for every Relay session pointed at that
server all flow through it tagged with `session_id` and `agent_name`.

On (re)connect the provider also calls `GET /events?since_id=<cursor>` to
backfill anything that happened while we were offline, advancing a durable
cursor stored in `PlatformSetting` so subsequent reconnects pick up where
we left off.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

import httpx
import websockets

from app.services.llm.base import LLMProvider

logger = logging.getLogger(__name__)


# Events that belong to an active turn — drained by the streaming generator
# for that session.
TURN_EVENT_TYPES = {
    "assistant_delta", "assistant_message", "thinking",
    "tool_call", "tool_result", "turn_usage", "done", "error",
}

# Async events: things that can fire even when no turn for that session is
# in flight (cross-session injections, file shares, errors).
#
# `project_file_changed` and `workspace_file_changed` are global to the ark
# server (no `session_id` field) — Relay forwards them to clients for live
# file-tree refresh in the side-panel. Per ark/docs the events are
# coalesced ~200ms server-side and ignore VCS/cache dirs.
ASYNC_EVENT_TYPES = {
    "file_available", "injected_message",
    "project_file_changed", "workspace_file_changed",
    # Compaction events fire on ark's /events stream any time the runtime
    # decides (or is asked) to summarise a session — they're conceptually
    # out-of-band from any given turn's assistant stream, so we route them
    # via the async callback rather than the per-turn queue.
    "compaction_started", "compaction_completed",
    "compaction_failed", "compaction_skipped",
    # Fired when a session's project binding changes (assign / reassign /
    # detach). Routed async because it happens outside any given turn — a
    # manual PATCH from a client, a CLI `ark session set-project`, etc.
    "session_project_changed",
    # `error` is also a TURN_EVENT_TYPE, drained by iter_turn_events for
    # in-flight turns Relay initiated. Listing it here so it ALSO reaches
    # the async callback when the turn belongs to a session Relay isn't
    # currently streaming (cron/heartbeat firing on the ark side, or a
    # catch-up replay after reconnect) — otherwise those errors are
    # silently dropped.
    "error",
}


def _agent_name(model: str) -> str:
    """Extract the ark agent name from an optional 'ark:<name>' prefix."""
    if model.startswith("ark:"):
        return model[len("ark:"):]
    return model


def _last_user_text(messages: list[dict[str, Any]]) -> str:
    """Ark owns history server-side, so we only need to send the most recent
    user message on each turn. Skips empty/whitespace-only entries — if any
    sneak through (e.g. synthetic file-attachment rows), they would otherwise
    shadow the real prompt and ark would receive an empty `user_message`."""
    for m in reversed(messages):
        if m.get("role") != "user":
            continue
        content = m.get("content") or ""
        if content.strip():
            return content
    return ""


@dataclass
class ArkResult:
    """Final yield from a streaming generation — carries the ark session_id
    so the caller can persist it for the next turn's chain, plus any
    `turn_usage` data ark reported for the completed turn (used by the
    client-side Diagnostics view)."""
    text: str
    session_id: str | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    model: str | None = None
    context_window: int | None = None


# Callback signature: receives the raw event dict (which always has
# `session_id` and usually `agent_name`).
AsyncEventCallback = Callable[[dict[str, Any]], Awaitable[None]]
CatchUpCallback = Callable[[dict[str, Any]], Awaitable[None]]


def _server_id_for(base_url: str, api_key: str | None = None) -> str:
    """Stable identifier for an ark backend — the normalized base URL.

    Used as the `server_id` tag on aggregated project listings, the
    PlatformSetting key suffix for the catch-up cursor, and the
    `sessions.project_server_id` column. Two different `api_key`s pointed
    at the same URL collapse to one identifier (intentional — the URL is
    the unit of deployment; the key is just credentials).

    Earlier revisions used `sha256(base_url|api_key)[:16]` — opaque in the
    operator prompt and in UI pickers. See `_legacy_server_id_for` for the
    migration helper that maps the old hash back to a URL.
    """
    return base_url.rstrip("/")


def _legacy_server_id_for(base_url: str, api_key: str | None) -> str:
    """The old SHA256-based identifier. Kept exclusively for one-time
    migration of `platform_settings.ark_cursor:*` keys and
    `sessions.project_server_id` values from hash to URL."""
    raw = f"{base_url.rstrip('/')}|{api_key or ''}".encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:16]


class ArkClientConnection:
    """One long-lived WebSocket to ark's `/events` for a single
    (base_url, api_key) pair. Multiplexes events for every session this
    token can see.

    Per-Relay-session turn state is held in `_turn_queues[ark_session_id]`,
    set/cleared around each `send_user_message` -> `iter_turn_events` call.
    All other events are dispatched to the registered `async_callback`.
    """

    def __init__(self, base_http: str, base_ws: str, api_key: str | None):
        self.base_http = base_http
        self.base_ws = base_ws
        self.api_key = api_key
        self.server_id = _server_id_for(base_http, api_key)

        self._ws: websockets.ClientConnection | None = None
        self._consumer: asyncio.Task | None = None
        self._turn_queues: dict[str, asyncio.Queue[tuple[int, dict]]] = {}
        self._async_callback: AsyncEventCallback | None = None
        # Called once per catch-up event so the backend can persist/broadcast.
        self._catch_up_callback: CatchUpCallback | None = None
        self._closed = False
        self._connect_lock = asyncio.Lock()
        # Per-session turn queue write lock (allow multiple concurrent turns
        # across different ark sessions on the same connection).
        self._turn_lock = asyncio.Lock()
        # Monotonic per-session turn generation. Bumped on every
        # send_user_message and send_stop. Dispatched events are tagged
        # with the generation observed at put-time so iter_turn_events
        # can drop stragglers from a previous (cancelled) turn — those
        # arrive in the *new* turn's queue because ark keeps emitting
        # after send_stop for a while and the session_id is reused
        # across turns (chain continuation).
        self._turn_generation: dict[str, int] = {}
        # High-water mark of ark event ids we've seen — live OR catch-up.
        # Written from `_dispatch_event`; flushed to platform_settings
        # by the periodic `_cursor_flusher` task. Without live tracking,
        # cursor only advances during catch-up passes, so a long-lived
        # Relay process's next restart replays every event since the
        # last catch-up — and `_handle_ark_event`'s 60-second dedupe
        # window misses them all, silently duplicating persisted rows.
        self._max_event_id_seen: int = 0
        # Value of `_max_event_id_seen` when we last called `set_cursor`.
        # Lets the flusher skip DB writes when nothing has moved.
        self._flushed_cursor: int = 0
        self._cursor_flusher: asyncio.Task | None = None

    # ── Public lifecycle ────────────────────────────────────────────

    def set_async_callback(self, cb: AsyncEventCallback | None) -> None:
        self._async_callback = cb

    def set_catch_up_callback(self, cb: CatchUpCallback | None) -> None:
        self._catch_up_callback = cb

    async def ensure_connected(self) -> None:
        async with self._connect_lock:
            if self._ws is not None and not self._closed:
                return
            await self._connect()

    async def close(self) -> None:
        self._closed = True
        if self._consumer:
            self._consumer.cancel()
            try:
                await self._consumer
            except (asyncio.CancelledError, Exception):
                pass
            self._consumer = None
        if self._cursor_flusher:
            # `_closed = True` above breaks out of the sleep loop and
            # runs the final flush inside the task itself. Cancel is
            # a belt-and-suspenders for the sleep case.
            self._cursor_flusher.cancel()
            try:
                await self._cursor_flusher
            except (asyncio.CancelledError, Exception):
                pass
            self._cursor_flusher = None
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None
        # Unblock any waiting turn consumer with a sentinel. Use the sid's
        # current generation so the sentinel isn't dropped as stale.
        for sid, q in self._turn_queues.items():
            gen = self._turn_generation.get(sid, 0)
            await q.put((gen, {"type": "done", "_closed": True}))

    # ── Turn API ────────────────────────────────────────────────────

    async def send_user_message(self, ark_session_id: str, text: str) -> int:
        """Open a turn for `ark_session_id` and send the user message. Returns
        the turn generation the caller should use with `iter_turn_events`;
        events tagged with an older generation (leftovers from a cancelled
        turn on the same session_id) get filtered out."""
        await self.ensure_connected()
        async with self._turn_lock:
            gen = self._turn_generation.get(ark_session_id, 0) + 1
            self._turn_generation[ark_session_id] = gen
            self._turn_queues[ark_session_id] = asyncio.Queue()
        assert self._ws is not None
        await self._ws.send(json.dumps({
            "type": "user_message",
            "session_id": ark_session_id,
            "text": text,
        }))
        return gen

    async def iter_turn_events(self, ark_session_id: str, generation: int):
        """Yield events for the named ark session's turn identified by
        `generation`, until a `done` is observed. Events tagged with an
        older generation are silently dropped — they belong to a prior
        turn that was cancelled but whose ark-side output was still in
        flight when this turn's queue was created. Removes the queue when
        finished."""
        queue = self._turn_queues.get(ark_session_id)
        if queue is None:
            return
        try:
            while True:
                event_gen, event = await queue.get()
                if event_gen != generation:
                    # Stale event from a previous, cancelled turn on the
                    # same session_id. Silently drop.
                    continue
                yield event
                if event.get("type") == "done":
                    break
        finally:
            async with self._turn_lock:
                self._turn_queues.pop(ark_session_id, None)

    async def send_stop(
        self, ark_session_id: str, *, bump_generation: bool = True,
    ) -> None:
        """Send ark's `stop` command for the named session.

        `bump_generation` controls whether we invalidate the current turn
        on our side (dropping any straggler events tagged with it):

        - `True` (default, used from iter_turn_events' CancelledError
          branch): the local iterator is about to die. Bump so anything
          ark still emits for the cancelled turn — which may keep
          arriving for hundreds of ms after `stop` reaches ark — is
          dead-on-arrival for the NEXT turn on the same session_id.

        - `False` (used from the client-initiated stop-button path): the
          local iterator is STILL active and we want to receive ark's
          terminal `done {stopped: true}` event so conversation_manager
          can persist the partial response as interrupted. Bumping here
          would drop that terminal event as stale and leave the client's
          streaming bubble hanging.
        """
        if bump_generation:
            async with self._turn_lock:
                self._turn_generation[ark_session_id] = (
                    self._turn_generation.get(ark_session_id, 0) + 1
                )
        if self._ws is None:
            return
        try:
            await asyncio.wait_for(self._ws.send(json.dumps({
                "type": "stop",
                "session_id": ark_session_id,
            })), timeout=0.5)
        except Exception:
            pass

    # ── Internals ───────────────────────────────────────────────────

    async def _open_ws(self) -> None:
        """Open (or re-open) the WS and run catch-up. Does NOT start the
        consumer task — that's `_connect`'s job for first-time setup, and
        `_consume`'s own reconnect loop just re-opens the socket inline
        (spawning a new consumer from inside `_consume` would leave the
        existing task running and produce a second concurrent
        `recv()` on the same connection, which `websockets` refuses with
        `ConcurrencyError`)."""
        url = f"{self.base_ws}/events"
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else None
        self._ws = await websockets.connect(url, additional_headers=headers, max_size=None)
        logger.info("Ark client WS connected: server=%s", self.server_id)

        # Run catch-up BEFORE the consumer starts (or resumes) reading so
        # the gap between last-stored cursor and "now" is filled before
        # we begin handling new events. Live events arriving during
        # catch-up are queued by the WS library and processed when the
        # consumer's `async for` starts (or picks back up).
        if self._catch_up_callback:
            try:
                await self._run_catch_up()
            except Exception:
                logger.exception("Ark catch-up failed (continuing with live stream)")

    async def _connect(self) -> None:
        """First-time setup: open the WS + run catch-up + spawn the
        singleton consumer task. Reconnects from inside `_consume` go
        through `_open_ws` instead, keeping the consumer task count at
        exactly one for the connection's whole life."""
        await self._open_ws()
        self._consumer = asyncio.create_task(
            self._consume(), name=f"ark-consumer-{self.server_id}",
        )
        if self._cursor_flusher is None:
            self._cursor_flusher = asyncio.create_task(
                self._flush_cursor_loop(),
                name=f"ark-cursor-flusher-{self.server_id}",
            )

    async def _flush_cursor_loop(self) -> None:
        """Persist `_max_event_id_seen` to the platform_settings cursor
        every few seconds while it's ahead of what's on disk. Without
        this, the cursor only advances during catch-up passes, and a
        long-lived Relay process's next restart replays every live
        event since the last catch-up — which `_handle_ark_event`'s
        60s text-based dedupe misses, silently duplicating messages."""
        from app.services.llm.ark_cursor import set_cursor
        while not self._closed:
            try:
                await asyncio.sleep(5.0)
            except asyncio.CancelledError:
                break
            hwm = self._max_event_id_seen
            if hwm > self._flushed_cursor:
                try:
                    await set_cursor(self.server_id, hwm)
                    self._flushed_cursor = hwm
                except Exception:
                    logger.exception(
                        "Ark cursor flush failed (server=%s hwm=%s)",
                        self.server_id, hwm,
                    )
        # Final flush on shutdown so the last few seconds of live
        # events don't get replayed on the next boot.
        hwm = self._max_event_id_seen
        if hwm > self._flushed_cursor:
            try:
                await set_cursor(self.server_id, hwm)
                self._flushed_cursor = hwm
            except Exception:
                logger.exception(
                    "Ark cursor final flush failed (server=%s hwm=%s)",
                    self.server_id, hwm,
                )

    async def _run_catch_up(self) -> None:
        """Pull persisted events since the stored cursor and hand each to the
        catch-up callback. Advances the cursor as we go."""
        from app.services.llm.ark_cursor import get_cursor, set_cursor

        cursor = await get_cursor(self.server_id)
        # Seed the live high-water mark from disk so a very early live
        # event (arriving before the flusher task runs) doesn't reset
        # our idea of what we've already persisted. Only bump forward.
        if isinstance(cursor, int) and cursor > self._max_event_id_seen:
            self._max_event_id_seen = cursor
        if isinstance(cursor, int) and cursor > self._flushed_cursor:
            self._flushed_cursor = cursor
        client = httpx.AsyncClient(timeout=30, headers=self._http_headers())
        try:
            # Pages, in case there's a lot. Cap at a few iterations to bound
            # startup time for first-ever connect (where cursor is None).
            for _ in range(20):
                params: dict[str, Any] = {"limit": 500}
                if cursor is not None:
                    params["since_id"] = cursor
                resp = await client.get(self.base_http + "/events", params=params)
                resp.raise_for_status()
                data = resp.json()
                events = data.get("events", [])
                if not events:
                    new_cursor = data.get("next_since_id")
                    if isinstance(new_cursor, int) and new_cursor != cursor:
                        cursor = new_cursor
                    break
                for ev in events:
                    try:
                        if self._catch_up_callback:
                            await self._catch_up_callback(ev)
                    except Exception:
                        logger.exception("Ark catch-up event handler failed")
                new_cursor = data.get("next_since_id") or events[-1].get("id")
                if isinstance(new_cursor, int):
                    cursor = new_cursor
                if not data.get("has_more"):
                    break
        finally:
            await client.aclose()

        if isinstance(cursor, int):
            await set_cursor(self.server_id, cursor)
            # Keep the live tracker's baselines in sync so the flusher
            # doesn't rewrite the same value seconds later, and so any
            # live event with id <= cursor doesn't look like a regression.
            if cursor > self._max_event_id_seen:
                self._max_event_id_seen = cursor
            if cursor > self._flushed_cursor:
                self._flushed_cursor = cursor
        logger.info("Ark catch-up complete: server=%s cursor=%s", self.server_id, cursor)

    def _http_headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}

    async def _consume(self) -> None:
        """Read frames forever, dispatch by `session_id` to per-session turn
        queue or to the async callback. Reconnects on drop with backoff."""
        backoff = 1.0
        while not self._closed:
            assert self._ws is not None
            try:
                async for raw in self._ws:
                    try:
                        event = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    await self._dispatch_event(event)
                if self._closed:
                    return
                logger.warning("Ark WS closed by server, reconnecting…")
            except websockets.ConnectionClosed as exc:
                if self._closed:
                    return
                logger.warning(
                    "Ark WS connection closed (%s), reconnecting…", exc,
                )
            except Exception as exc:
                # Log the concrete exception type + message BEFORE the
                # traceback so a scan of the log can spot repeated
                # failure modes (e.g. `ConcurrencyError`) without having
                # to read every stack frame.
                logger.exception(
                    "Ark WS consumer error (%s: %s), reconnecting…",
                    type(exc).__name__, exc,
                )
            # Drop any in-flight turns — callers will surface the failure.
            # Tag with the sid's current generation so the error reaches
            # the waiting iterator instead of being dropped as stale.
            for sid, q in list(self._turn_queues.items()):
                gen = self._turn_generation.get(sid, 0)
                await q.put((gen, {"type": "error", "message": "Ark WS dropped mid-turn"}))
            self._ws = None
            await asyncio.sleep(min(backoff, 30.0))
            try:
                # Re-open the socket in place — must NOT spawn a fresh
                # consumer task (that's what `_connect` does for first-
                # time setup). Spawning one here would leave the current
                # `_consume` task alive, and the next `async for raw in
                # self._ws:` would race the new task's own `recv()`,
                # yielding `websockets.ConcurrencyError`.
                await self._open_ws()
                backoff = 1.0
            except Exception:
                logger.exception("Ark WS reconnect failed; backing off")
                backoff = min(backoff * 2.0, 30.0)

    async def _dispatch_event(self, event: dict) -> None:
        etype = event.get("type")
        sid = event.get("session_id")
        # Track the max event id we've seen. `_cursor_flusher` writes
        # this to the platform_settings cursor so the next restart's
        # catch-up starts from the true high-water mark, not from where
        # the previous restart's catch-up left off.
        #
        # Ark's contract (see ark CHANGELOG "event_id on live WS
        # events"): persisted-row events carry `event_id` matching the
        # same `messages.id` that `GET /events` returns. Ephemeral
        # events (assistant_delta / thinking / tool_call / per-turn
        # done / project_file_changed / etc.) omit it, and we must NOT
        # advance the cursor for them — the cursor is only meaningful
        # against ark's persisted event log.
        eid = event.get("event_id")
        if isinstance(eid, int) and eid > self._max_event_id_seen:
            self._max_event_id_seen = eid
        if etype in TURN_EVENT_TYPES and sid and sid in self._turn_queues:
            # Tag with the current generation so iter_turn_events can
            # drop stragglers from a previous, cancelled turn.
            gen = self._turn_generation.get(sid, 0)
            await self._turn_queues[sid].put((gen, event))
            return
        if etype in ASYNC_EVENT_TYPES or etype in TURN_EVENT_TYPES:
            # Includes turn events that weren't claimed by an in-flight
            # iter_turn_events (e.g. heartbeat/cron sessions running on the
            # ark side that this Relay process didn't initiate). The async
            # callback persists what it can.
            if self._async_callback:
                try:
                    await self._async_callback(event)
                except Exception:
                    logger.exception("Ark async callback failed (type=%s sid=%s)", etype, sid)


# ── Global registry: one connection per (base_url, api_key) ─────────


_connections: dict[str, ArkClientConnection] = {}
_registry_lock = asyncio.Lock()


def _conn_key(base_url: str, api_key: str | None) -> str:
    return _server_id_for(base_url, api_key)


async def get_or_create_connection(
    *, base_http: str, base_ws: str, api_key: str | None,
    async_cb: AsyncEventCallback | None = None,
    catch_up_cb: CatchUpCallback | None = None,
) -> ArkClientConnection:
    """Look up the live ark connection for an (base_url, api_key) pair, or
    open one. Callbacks are (re)installed every call — last-writer wins,
    which is fine because they all run the same dispatcher behind the scenes."""
    key = _conn_key(base_http, api_key)
    async with _registry_lock:
        conn = _connections.get(key)
        if conn is None or conn._closed:
            conn = ArkClientConnection(
                base_http=base_http, base_ws=base_ws, api_key=api_key,
            )
            _connections[key] = conn
    if async_cb is not None:
        conn.set_async_callback(async_cb)
    if catch_up_cb is not None:
        conn.set_catch_up_callback(catch_up_cb)
    await conn.ensure_connected()
    return conn


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


def get_connection_by_key(key: str) -> ArkClientConnection | None:
    return _connections.get(key)


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
        session_context: str | None = None,
        project_id: str | None = None,
    ) -> ArkResult:
        chunks: list[str] = []
        final: ArkResult | None = None
        async for item in self.generate_stream_with_chain(
            system_prompt, messages, model,
            relay_session_id=relay_session_id,
            previous_session_id=previous_session_id,
            session_context=session_context,
            project_id=project_id,
        ):
            if isinstance(item, str):
                chunks.append(item)
            elif isinstance(item, ArkResult):
                final = item
        return ArkResult(
            text="".join(chunks),
            session_id=final.session_id if final else None,
            input_tokens=final.input_tokens if final else None,
            output_tokens=final.output_tokens if final else None,
            model=final.model if final else None,
            context_window=final.context_window if final else None,
        )

    async def generate_stream_with_chain(
        self,
        system_prompt,  # ark composes its own system prompt; persona flows via session_context
        messages,
        model,
        relay_session_id: str | None = None,
        previous_session_id: str | None = None,
        session_context: str | None = None,
        project_id: str | None = None,
    ):
        agent = _agent_name(model)
        user_text = _last_user_text(messages)
        logger.info(
            "Ark stream: agent=%s, chain=%s, %d chars",
            agent, previous_session_id is not None, len(user_text),
        )

        ark_session_id = previous_session_id or await self._ensure_session(
            agent, context=session_context, project_id=project_id,
        )
        # Surface the ark session id BEFORE we start streaming so the
        # agent_manager can persist it into provider_state right away.
        # Waiting until the final ArkResult (end of turn) means an early
        # Stop press during the very first turn of a fresh session can't
        # find the ark_sid to cancel — see `_forward_stop_to_ark` in
        # api/websocket.py, which returns silently on missing ark_sid.
        yield {"__ark_session__": ark_session_id}

        # The agent_manager has the user_id context to install the proper
        # async/catch-up callbacks. We just look up the connection here.
        conn = get_connection_by_key(_conn_key(self._base_http, self._api_key))
        if conn is None:
            # The connection should have been opened by the agent_manager
            # before invoking us — but if not, create a bare one. Async
            # events will be dropped until a callback is installed.
            conn = await get_or_create_connection(
                base_http=self._base_http,
                base_ws=self._base_ws,
                api_key=self._api_key,
            )

        # Multi-segment assistant text: ark emits multiple delta streams
        # separated by `assistant_message` boundary events around tool calls.
        # Insert a paragraph break before the first delta of each new segment.
        turn_gen = await conn.send_user_message(ark_session_id, user_text)
        saw_segment_end = False
        usage_in: int | None = None
        usage_out: int | None = None
        usage_model: str | None = None
        usage_ctx: int | None = None
        try:
            async for event in conn.iter_turn_events(ark_session_id, turn_gen):
                etype = event.get("type")
                if etype == "assistant_delta":
                    delta = event.get("text") or event.get("delta") or ""
                    if delta:
                        if saw_segment_end:
                            yield "\n\n"
                            saw_segment_end = False
                        yield delta
                elif etype == "assistant_message":
                    saw_segment_end = True
                elif etype == "turn_usage":
                    # Multi-segment turns can emit `turn_usage` more than once
                    # (once per LLM call). Keep the cumulative input/output and
                    # the last-seen context_window/model.
                    in_t = event.get("input_tokens")
                    out_t = event.get("output_tokens")
                    if isinstance(in_t, int):
                        usage_in = (usage_in or 0) + in_t
                    if isinstance(out_t, int):
                        usage_out = (usage_out or 0) + out_t
                    if isinstance(event.get("context_window"), int):
                        usage_ctx = event["context_window"]
                    if isinstance(event.get("model"), str) and event["model"]:
                        usage_model = event["model"]
                elif etype == "error":
                    # Surface upward so conversation_manager can persist a
                    # `role="error"` marker + broadcast a `session_error`
                    # WS event. Same envelope convention as `__activity__`
                    # — a dict chunk that downstream distinguishes from
                    # string deltas by isinstance check.
                    logger.warning("Ark error event: %s", event.get("message"))
                    yield {"__error__": {
                        "code": event.get("code") or "other",
                        "message": event.get("message") or "",
                    }}
                elif etype == "done":
                    # Ark's new mid-turn stop path lands here with
                    # `stopped: true` (and `stop_reason: "stopped"`).
                    # Surface that upward so conversation_manager can
                    # persist the partial response as interrupted and
                    # emit `text_done {interrupted: true}` — otherwise
                    # a client-initiated stop would look like a clean
                    # completion from the UI's perspective.
                    if event.get("stopped"):
                        yield {"__stopped__": {
                            "stop_reason": event.get("stop_reason") or "stopped",
                        }}
                    break
                elif etype in ("thinking", "tool_call", "tool_result"):
                    # Surface as an opaque dict so downstream (agent_manager
                    # → conversation_manager) can translate it into a
                    # user-visible `agent_activity` WS event. Distinguished
                    # from str deltas by isinstance(chunk, dict).
                    yield {"__activity__": etype, "payload": event}
        except asyncio.CancelledError:
            await conn.send_stop(ark_session_id)
            raise

        yield ArkResult(
            text="",
            session_id=ark_session_id,
            input_tokens=usage_in,
            output_tokens=usage_out,
            model=usage_model,
            context_window=usage_ctx,
        )

    # ── Helpers ─────────────────────────────────────────────────────

    async def _ensure_session(
        self, agent: str, context: str | None = None,
        project_id: str | None = None,
    ) -> str:
        """Create a new ark session and return its id. If `context` is given,
        ark seeds it as a SessionContext on creation. If `project_id` is
        given, the session is bound to that ark project (immutable for life
        of session — see docs/projects.md)."""
        url = f"{self._base_http}/agents/{agent}/sessions"
        headers = {"Authorization": f"Bearer {self._api_key}"} if self._api_key else {}
        body: dict[str, str] = {}
        if context and context.strip():
            body["context"] = context.strip()
        if project_id:
            body["project_id"] = project_id
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, headers=headers, json=body)
            resp.raise_for_status()
            data = resp.json()
            session_id = data.get("id") or data.get("session_id")
            if not session_id:
                raise RuntimeError(f"Ark session creation returned no id: {data}")
            logger.info("Ark session created: agent=%s session=%s", agent, session_id)
            return session_id
