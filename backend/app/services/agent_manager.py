"""Agent Manager — resolves agent identity and generates responses via LLM providers."""

from __future__ import annotations

import logging
import uuid
from collections.abc import AsyncGenerator
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.agent import Agent
from app.services import agent_health
from app.services.llm import get_provider
from app.services.llm.ark import ArkProvider
from app.services.llm.openclaw import OpenClawProvider


@dataclass
class ResponseMeta:
    """Sentinel yielded as the final item from `generate_response_stream` to
    hand back per-turn metadata (token usage, model, etc.) so the caller can
    persist it on the assistant message and surface it to clients with
    Diagnostics enabled."""
    metadata: dict[str, Any] = field(default_factory=dict)

logger = logging.getLogger(__name__)


async def get_agent_by_name(db: AsyncSession, name: str) -> Agent | None:
    """Case-insensitive lookup by agent display name (skipping soft-deletes).

    There can be multiple rows with the same name if an agent was deleted and
    recreated, so we explicitly filter out soft-deleted rows and pick the
    most-recently-created remaining match if more than one is live.
    """
    result = await db.execute(
        select(Agent)
            .where(Agent.name.ilike(name), Agent.deleted_at.is_(None))
            .order_by(Agent.agent_id.desc())
    )
    return result.scalars().first()


async def get_agent_by_id(db: AsyncSession, agent_id: uuid.UUID) -> Agent | None:
    # `populate_existing()` forces SQLAlchemy to refresh attributes on any
    # object that's already in the identity map. Without it, long-lived
    # sessions (e.g. the WebSocket session) keep returning a stale Agent
    # whose voice_id / tts_provider / etc. were captured at first load,
    # because `expire_on_commit=False` is set on the sessionmaker.
    result = await db.execute(
        select(Agent).where(Agent.agent_id == agent_id).execution_options(populate_existing=True)
    )
    return result.scalar_one_or_none()


async def list_agents(db: AsyncSession) -> list[Agent]:
    result = await db.execute(
        select(Agent).where(Agent.name != "Operator", Agent.deleted_at.is_(None))
            .order_by(Agent.sort_order, Agent.name)
    )
    return list(result.scalars().all())


async def list_all_agents(db: AsyncSession) -> list[Agent]:
    """List all agents including the Operator."""
    result = await db.execute(
        select(Agent).where(Agent.deleted_at.is_(None)).order_by(Agent.sort_order, Agent.name)
    )
    return list(result.scalars().all())


_VOICE_PREAMBLE = (
    "This is a voice conversation. Keep responses short and conversational — "
    "1-3 sentences unless the user asks for detail. Favor natural turn-taking "
    "over long monologues. Do not use markdown, lists, or formatting.\n\n"
)


def _build_system_prompt(agent: Agent, voice_instructions: str | None = None) -> str:
    persona = agent.persona_prompt or f"You are {agent.name}, a helpful assistant."
    preamble = (voice_instructions.strip() + "\n\n") if voice_instructions else _VOICE_PREAMBLE
    return preamble + persona


def _append_voice_note(messages: list[dict], voice_instructions: str) -> list[dict]:
    """Append a style note to the last user message in-memory (not persisted).

    Used for providers like OpenClaw that manage their own system prompt — we
    can't override their context, so we nudge the model via the user turn instead.
    """
    modified = list(messages)
    for i in range(len(modified) - 1, -1, -1):
        if modified[i]["role"] == "user":
            modified[i] = {
                **modified[i],
                "content": modified[i]["content"] + f"\n\n[Style note: {voice_instructions}]",
            }
            return modified
    return modified


async def resolve_llm_config(agent: Agent) -> tuple[str | None, str | None]:
    """Apply platform-default fallback for base_url + api_key when the agent's
    own values are empty. Keeps the per-agent values authoritative."""
    base_url = agent.llm_base_url
    api_key = agent.llm_api_key
    if not base_url:
        base_url = await _get_platform_setting(f"llm_{agent.llm_provider}_base_url") or None
    if not api_key:
        api_key = await _get_platform_setting(f"llm_{agent.llm_provider}_api_key") or None
    return base_url, api_key


async def resolve_tts_config(agent: Agent) -> tuple[str | None, str | None]:
    """Same idea for TTS: platform default for tts_api_key and base_url
    when the agent's own values are empty."""
    api_key = agent.tts_api_key
    base_url = (agent.voice_settings or {}).get("base_url") if isinstance(agent.voice_settings, dict) else None
    if not api_key and agent.tts_provider:
        api_key = await _get_platform_setting(f"tts_{agent.tts_provider}_api_key") or None
    if not base_url and agent.tts_provider:
        base_url = await _get_platform_setting(f"tts_{agent.tts_provider}_base_url") or None
    return base_url, api_key


async def _get_platform_setting(key: str) -> str:
    """Read a single platform setting outside any active session — used by
    the LLM/TTS resolution paths."""
    from app.db.database import async_session
    from app.models.platform_setting import PlatformSetting
    async with async_session() as db:
        result = await db.execute(
            select(PlatformSetting).where(PlatformSetting.key == key)
        )
        row = result.scalar_one_or_none()
        return row.value if row else ""


async def generate_response(
    agent: Agent, text: str, context: list[dict],
    voice_instructions: str | None = None,
    session_id: uuid.UUID | None = None,
) -> str:
    """Generate a text response from an agent using its configured LLM provider."""
    base_url, api_key = await resolve_llm_config(agent)
    provider = get_provider(agent.llm_provider, base_url, api_key)
    if provider is None:
        agent_health.set_error(agent.agent_id, f"{agent.llm_provider} API key not configured")
        return (
            f"[{agent.name}] LLM provider '{agent.llm_provider}' is not configured. "
            f"Please check the API key for this provider."
        )

    # Convert internal message format to LLM format
    messages = []
    for msg in context:
        role = "assistant" if msg["role"] == "agent" else msg["role"]
        if role in ("user", "assistant"):
            messages.append({"role": role, "content": msg["text_content"]})

    if voice_instructions and isinstance(provider, (OpenClawProvider, ArkProvider)):
        # OpenClaw and ark manage their own system prompts server-side and
        # ignore the one Relay constructs — so inject the voice/live style
        # nudge onto the last user message instead.
        messages = _append_voice_note(messages, voice_instructions)
        system_prompt = _build_system_prompt(agent)
    else:
        system_prompt = _build_system_prompt(agent, voice_instructions)

    # OpenClaw: use response chaining
    if isinstance(provider, OpenClawProvider) and session_id:
        from app.db.redis import get_openclaw_response_id, set_openclaw_response_id

        prev_id = await get_openclaw_response_id(str(session_id))
        try:
            result = await provider.generate_with_chain(
                system_prompt, messages, agent.llm_model,
                previous_response_id=prev_id,
            )
            if result.response_id:
                await set_openclaw_response_id(str(session_id), result.response_id)
            agent_health.set_healthy(agent.agent_id)
            return result.text
        except Exception as exc:
            logger.exception("LLM call failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            return f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."

    # Ark: each Relay session pins to a server-side ark session_id stored in
    # provider_state['ark']. Ark owns history; we only send the last turn.
    if isinstance(provider, ArkProvider) and session_id:
        from app.db.redis import get_provider_state, set_provider_state

        await ensure_ark_connection(agent)
        prev_sid = await get_provider_state(str(session_id), "ark")
        try:
            result = await provider.generate_with_chain(
                system_prompt, messages, agent.llm_model,
                relay_session_id=str(session_id),
                previous_session_id=prev_sid,
                session_context=agent.persona_prompt if not prev_sid else None,
            )
            if result.session_id:
                await set_provider_state(str(session_id), "ark", result.session_id)
            agent_health.set_healthy(agent.agent_id)
            return result.text
        except Exception as exc:
            logger.exception("LLM call failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            return f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."

    try:
        result = await provider.generate(system_prompt, messages, agent.llm_model)
        agent_health.set_healthy(agent.agent_id)
        return result
    except Exception as exc:
        logger.exception("LLM call failed for agent %s: %s", agent.name, exc)
        agent_health.set_error(agent.agent_id, str(exc)[:120])
        return f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."


async def generate_response_stream(
    agent: Agent, text: str, context: list[dict],
    voice_instructions: str | None = None,
    session_id: uuid.UUID | None = None,
) -> AsyncGenerator[str | ResponseMeta, None]:
    """Stream a text response from an agent using its configured LLM provider."""
    base_url, api_key = await resolve_llm_config(agent)
    provider = get_provider(agent.llm_provider, base_url, api_key)
    if provider is None:
        agent_health.set_error(agent.agent_id, f"{agent.llm_provider} API key not configured")
        yield (
            f"[{agent.name}] LLM provider '{agent.llm_provider}' is not configured. "
            f"Please check the API key for this provider."
        )
        return

    messages = []
    for msg in context:
        role = "assistant" if msg["role"] == "agent" else msg["role"]
        if role in ("user", "assistant"):
            messages.append({"role": role, "content": msg["text_content"]})

    if voice_instructions and isinstance(provider, (OpenClawProvider, ArkProvider)):
        # OpenClaw and ark manage their own system prompts server-side and
        # ignore the one Relay constructs — so inject the voice/live style
        # nudge onto the last user message instead.
        messages = _append_voice_note(messages, voice_instructions)
        system_prompt = _build_system_prompt(agent)
    else:
        system_prompt = _build_system_prompt(agent, voice_instructions)

    # OpenClaw: use response chaining instead of sending full history each time
    if isinstance(provider, OpenClawProvider) and session_id:
        from app.db.redis import get_openclaw_response_id, set_openclaw_response_id
        from app.services.llm.openclaw import OpenClawResult

        prev_id = await get_openclaw_response_id(str(session_id))
        try:
            async for chunk in provider.generate_stream_with_chain(
                system_prompt, messages, agent.llm_model,
                previous_response_id=prev_id,
            ):
                if isinstance(chunk, OpenClawResult):
                    if chunk.response_id:
                        await set_openclaw_response_id(str(session_id), chunk.response_id)
                else:
                    yield chunk
            agent_health.set_healthy(agent.agent_id)
        except Exception as exc:
            logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."
        return

    # Ark: same chain pattern but with a server-issued session_id.
    if isinstance(provider, ArkProvider) and session_id:
        from app.db.redis import get_provider_state, set_provider_state
        from app.services.llm.ark import ArkResult

        await ensure_ark_connection(agent)
        prev_sid = await get_provider_state(str(session_id), "ark")
        final_meta: dict[str, Any] = {}
        try:
            async for chunk in provider.generate_stream_with_chain(
                system_prompt, messages, agent.llm_model,
                relay_session_id=str(session_id),
                previous_session_id=prev_sid,
                session_context=agent.persona_prompt if not prev_sid else None,
            ):
                if isinstance(chunk, ArkResult):
                    if chunk.session_id:
                        await set_provider_state(str(session_id), "ark", chunk.session_id)
                    # Build the usage payload only if ark reported any token
                    # numbers. Keeps the metadata dict empty for turns where
                    # ark didn't surface usage (older harness, fallback paths).
                    if chunk.input_tokens is not None or chunk.output_tokens is not None:
                        usage: dict[str, Any] = {}
                        if chunk.input_tokens is not None:
                            usage["input_tokens"] = chunk.input_tokens
                        if chunk.output_tokens is not None:
                            usage["output_tokens"] = chunk.output_tokens
                        if chunk.context_window is not None:
                            usage["context_window"] = chunk.context_window
                        if chunk.model:
                            usage["model"] = chunk.model
                        final_meta["usage"] = usage
                else:
                    yield chunk
            agent_health.set_healthy(agent.agent_id)
        except Exception as exc:
            logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."
        if final_meta:
            yield ResponseMeta(metadata=final_meta)
        return

    try:
        async for chunk in provider.generate_stream(system_prompt, messages, agent.llm_model):
            yield chunk
        agent_health.set_healthy(agent.agent_id)
    except Exception as exc:
        logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
        agent_health.set_error(agent.agent_id, str(exc)[:120])
        yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."


# ── Ark async-event fan-out ─────────────────────────────────────────


async def ensure_ark_connection(agent: Agent) -> None:
    """Idempotently open (or reuse) the per-server ark connection for an
    agent, install the dispatch callbacks, and let it run its catch-up.

    Called at the start of every ark turn and from session resume so the
    backend keeps one warm connection per (base_url, api_key) pair, with
    callbacks routing events to whichever Relay session/user they belong to.
    """
    from app.services.llm.ark import get_or_create_connection

    base_url, api_key = await resolve_llm_config(agent)
    if not base_url:
        return
    http = base_url.rstrip("/")
    ws = http.replace("http://", "ws://", 1).replace("https://", "wss://", 1)
    await get_or_create_connection(
        base_http=http, base_ws=ws, api_key=api_key,
        async_cb=_ark_dispatch,
        catch_up_cb=_ark_catch_up_dispatch,
    )


async def _resolve_relay_session_for_ark(
    ark_session_id: str,
) -> tuple[str | None, str | None]:
    """Given an ark session_id, find (relay_session_id, user_id) for the
    matching Relay session. Returns (None, None) if no Relay session is
    pinned to this ark session — common for heartbeat/cron sessions that
    were created server-side without Relay's involvement."""
    from app.db.database import async_session
    from app.models.session import Session
    async with async_session() as db:
        result = await db.execute(
            select(Session.session_id, Session.user_id)
                .where(Session.deleted_at.is_(None))
                .where(Session.provider_state["ark"].astext == ark_session_id)
        )
        row = result.first()
        if row is None:
            return None, None
        return str(row[0]), row[1]


async def _ark_dispatch(event: dict) -> None:
    """Dispatcher for live WS events from any ark session this connection
    sees. Resolves the matching Relay session by `session_id`, persists what
    needs persisting, broadcasts to the right user."""
    sid = event.get("session_id")
    if not sid:
        return
    relay_sid, user_id = await _resolve_relay_session_for_ark(sid)
    if not relay_sid or not user_id:
        return  # this ark session isn't mirrored on Relay
    agent_name = event.get("agent_name") or "agent"
    await _handle_ark_event(
        event=event,
        relay_session_id=relay_sid,
        user_id=user_id,
        agent_name=agent_name,
        is_catch_up=False,
    )


async def _ark_catch_up_dispatch(event: dict) -> None:
    """Dispatcher for catch-up events from `GET /events?since_id=...`.

    Shape is different from the live WS frames — catch-up gives
    `{id, session_id, agent_name, created_at, kind, data}` rather than the
    flat WS payload. We translate to the same shape `_handle_ark_event`
    expects."""
    sid = event.get("session_id")
    if not sid:
        return
    relay_sid, user_id = await _resolve_relay_session_for_ark(sid)
    if not relay_sid or not user_id:
        return
    agent_name = event.get("agent_name") or "agent"
    kind = event.get("kind")
    data = event.get("data") or {}
    # Map kind → live-shape event for unified handling. Only kinds with a
    # user-visible side effect on Relay are handled; the rest (ToolCall,
    # ToolResult, SessionContext, UserText) are ignored on catch-up.
    if kind == "AssistantText":
        text = data.get("text") or ""
        if text:
            await _handle_ark_event(
                event={"type": "assistant_message", "text": text},
                relay_session_id=relay_sid, user_id=user_id, agent_name=agent_name,
                is_catch_up=True,
            )
    elif kind == "InjectedMessage":
        text = data.get("text") or ""
        if text:
            await _handle_ark_event(
                event={"type": "injected_message", "text": text},
                relay_session_id=relay_sid, user_id=user_id, agent_name=agent_name,
                is_catch_up=True,
            )
    elif kind == "SharedFile":
        path = data.get("path")
        if path:
            await _handle_ark_event(
                event={
                    "type": "file_available",
                    "path": path,
                    "description": data.get("description"),
                    "size": data.get("size") or 0,
                },
                relay_session_id=relay_sid, user_id=user_id, agent_name=agent_name,
                is_catch_up=True,
            )


async def _handle_ark_event(
    *,
    event: dict,
    relay_session_id: str,
    user_id: str,
    agent_name: str,
    is_catch_up: bool,
) -> None:
    """Persist + broadcast a single ark event, marking the Relay session
    `has_unread` if the user isn't currently viewing it."""
    from app.api.websocket import _broadcast_to_user

    etype = event.get("type")

    if etype == "file_available":
        path = event.get("path")
        size = event.get("size") or 0
        if not path:
            return
        existing = await _file_already_persisted(relay_session_id, path)
        if existing is None:
            file_id = await _persist_agent_shared_file(
                user_id=user_id, session_id_str=relay_session_id,
                agent_name=agent_name, path=path, size=size,
            )
        else:
            file_id = existing
        if not is_catch_up:
            await _broadcast_to_user(user_id, {
                "type": "agent_file",
                "payload": {
                    "session_id": relay_session_id,
                    "agent_name": agent_name,
                    "path": path,
                    "description": event.get("description"),
                    "size": size,
                    "file_id": file_id,
                },
            })
        await _maybe_mark_unread(user_id, relay_session_id)
        return

    if etype == "injected_message":
        text = event.get("text") or event.get("message") or ""
        if not text:
            return
        if not await _message_already_persisted(relay_session_id, text, role="agent"):
            await _persist_injected_message(session_id_str=relay_session_id, text=text)
        if not is_catch_up:
            # Tag the broadcast with the target session_id so clients only
            # render it in the right pane. Without this, every connected
            # client appends the text to whichever session it's currently
            # viewing — looking like the message went "to the wrong place."
            await _broadcast_to_user(user_id, {
                "type": "text",
                "payload": {
                    "speaker": agent_name,
                    "text": text,
                    "session_id": relay_session_id,
                },
            })
        await _maybe_mark_unread(user_id, relay_session_id)
        return

    if etype == "assistant_message" and is_catch_up:
        # Catch-up replay of an agent text turn we didn't see live (most
        # likely a heartbeat or cron turn). Persist as an agent message so
        # the user sees it next time they open the session.
        text = event.get("text") or ""
        if not text:
            return
        if not await _message_already_persisted(relay_session_id, text, role="agent"):
            await _persist_injected_message(session_id_str=relay_session_id, text=text)
            await _maybe_mark_unread(user_id, relay_session_id)
        return


async def _file_already_persisted(session_id_str: str, path: str) -> str | None:
    """Return the file_id of an existing File row for this session+path, or
    None. Used to dedupe between WS-driven and catch-up-driven inserts."""
    from app.db.database import async_session
    from app.models.file import File as FileModel
    import uuid as _uuid
    storage_path_substr = f":{path}"  # ark storage paths are ark:<agent>:<path>
    async with async_session() as db:
        result = await db.execute(
            select(FileModel.file_id).where(
                FileModel.session_id == _uuid.UUID(session_id_str),
                FileModel.storage_path.like(f"ark:%{storage_path_substr}"),
            ).limit(1)
        )
        row = result.scalar_one_or_none()
        return str(row) if row else None


async def _message_already_persisted(
    session_id_str: str, text: str, *, role: str, within_seconds: int = 60,
) -> bool:
    """Recent-duplicate check: do we already have an exact-text message in
    this session from the last `within_seconds`? Bounded by time so that
    legitimate repeats (e.g. a cron firing the same line every minute)
    flow through while a WS↔catch-up race on reconnect (which happens
    within seconds) is still deduped."""
    from app.db.database import async_session
    from app.models.message import Message as MessageModel
    from datetime import datetime, timedelta, timezone
    import uuid as _uuid

    cutoff = datetime.now(timezone.utc) - timedelta(seconds=within_seconds)
    async with async_session() as db:
        result = await db.execute(
            select(MessageModel.message_id).where(
                MessageModel.session_id == _uuid.UUID(session_id_str),
                MessageModel.role == role,
                MessageModel.text_content == text,
                MessageModel.created_at >= cutoff,
            ).limit(1)
        )
        return result.scalar_one_or_none() is not None


async def _maybe_mark_unread(user_id: str, relay_session_id: str) -> None:
    """If the Relay session isn't currently active for this user, set
    `has_unread=true` and broadcast so the sidebar shows the indicator."""
    from app.db.database import async_session
    from app.db.redis import invalidate_session_cache
    from app.models.session import Session
    from app.api.websocket import _broadcast_to_user
    import uuid as _uuid

    async with async_session() as db:
        result = await db.execute(
            select(Session).where(Session.session_id == _uuid.UUID(relay_session_id))
        )
        sess = result.scalar_one_or_none()
        if sess is None:
            return
        # If user is mid-session, don't badge it.
        if sess.status == "active":
            return
        if sess.has_unread:
            return
        sess.has_unread = True
        await db.commit()
        await invalidate_session_cache(relay_session_id)
    await _broadcast_to_user(user_id, {
        "type": "session_unread",
        "payload": {"session_id": relay_session_id, "has_unread": True},
    })


async def _persist_injected_message(*, session_id_str: str, text: str) -> None:
    """Write a cross-session-injected ark message as an `agent`-role row in
    Relay's messages table. Invalidates the session history cache."""
    from app.db.database import async_session
    from app.db.redis import invalidate_session_cache
    from app.models.message import Message as MessageModel
    import uuid as _uuid

    try:
        async with async_session() as db:
            db_msg = MessageModel(
                session_id=_uuid.UUID(session_id_str),
                role="agent",
                text_content=text,
            )
            db.add(db_msg)
            await db.commit()
            await invalidate_session_cache(session_id_str)
    except Exception:
        logger.exception("Failed to persist injected_message")


async def _persist_injected_message(*, session_id_str: str, text: str) -> None:
    """Write a cross-session-injected ark message as an `agent`-role row in
    Relay's messages table. Invalidates the session history cache."""
    from app.db.database import async_session
    from app.db.redis import invalidate_session_cache
    from app.models.message import Message as MessageModel
    import uuid as _uuid

    try:
        async with async_session() as db:
            db_msg = MessageModel(
                session_id=_uuid.UUID(session_id_str),
                role="agent",
                text_content=text,
            )
            db.add(db_msg)
            await db.commit()
            await invalidate_session_cache(session_id_str)
    except Exception:
        logger.exception("Failed to persist injected_message")


async def _persist_agent_shared_file(
    *, user_id: str, session_id_str: str, agent_name: str, path: str, size: int,
) -> str | None:
    """Record an agent-pushed file as a `files` row so session history can
    replay it. Returns the new file_id (string) or None on failure."""
    from app.db.database import async_session
    from app.db.redis import invalidate_session_cache
    from app.models.file import File as FileModel
    import uuid as _uuid

    filename = path.rsplit("/", 1)[-1] or "file"
    storage_path = f"ark:{agent_name}:{path}"
    try:
        async with async_session() as db:
            db_file = FileModel(
                file_id=_uuid.uuid4(),
                session_id=_uuid.UUID(session_id_str),
                user_id=user_id,
                filename=filename,
                mime_type="application/octet-stream",
                size_bytes=int(size or 0),
                storage_path=storage_path,
                role="agent",
            )
            db.add(db_file)
            await db.commit()
            await invalidate_session_cache(session_id_str)
            return str(db_file.file_id)
    except Exception:
        logger.exception("Failed to persist agent-shared file")
        return None
