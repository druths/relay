"""Agent Manager — resolves agent identity and generates responses via LLM providers."""

from __future__ import annotations

import logging
import uuid
from collections.abc import AsyncGenerator

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.agent import Agent
from app.services import agent_health
from app.services.llm import get_provider
from app.services.llm.ark import ArkProvider
from app.services.llm.openclaw import OpenClawProvider

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


async def generate_response(
    agent: Agent, text: str, context: list[dict],
    voice_instructions: str | None = None,
    session_id: uuid.UUID | None = None,
) -> str:
    """Generate a text response from an agent using its configured LLM provider."""
    provider = get_provider(agent.llm_provider, agent.llm_base_url, agent.llm_api_key)
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

        prev_sid = await get_provider_state(str(session_id), "ark")
        try:
            result = await provider.generate_with_chain(
                system_prompt, messages, agent.llm_model,
                relay_session_id=str(session_id),
                previous_session_id=prev_sid,
            )
            if result.session_id:
                await set_provider_state(str(session_id), "ark", result.session_id)
            await _ensure_ark_async_listener(agent, session_id, result.session_id)
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
) -> AsyncGenerator[str, None]:
    """Stream a text response from an agent using its configured LLM provider."""
    provider = get_provider(agent.llm_provider, agent.llm_base_url, agent.llm_api_key)
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

        prev_sid = await get_provider_state(str(session_id), "ark")
        final_ark_sid: str | None = None
        try:
            async for chunk in provider.generate_stream_with_chain(
                system_prompt, messages, agent.llm_model,
                relay_session_id=str(session_id),
                previous_session_id=prev_sid,
            ):
                if isinstance(chunk, ArkResult):
                    if chunk.session_id:
                        await set_provider_state(str(session_id), "ark", chunk.session_id)
                        final_ark_sid = chunk.session_id
                else:
                    yield chunk
            agent_health.set_healthy(agent.agent_id)
            if final_ark_sid:
                await _ensure_ark_async_listener(agent, session_id, final_ark_sid)
        except Exception as exc:
            logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."
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

async def _ensure_ark_async_listener(
    agent: Agent, relay_session_id: uuid.UUID, ark_session_id: str,
) -> None:
    """Make sure the ArkSessionConnection for this Relay session has a
    callback wired that fans out file_available / injected_message events to
    the user's Relay WS clients."""
    from app.services.llm.ark import get_connection

    conn = get_connection(str(relay_session_id))
    if conn is None:
        return
    # Idempotent — the connection holds a single slot; we just overwrite.
    user_id = await _resolve_session_user_id(relay_session_id)
    if not user_id:
        return

    sid_str = str(relay_session_id)
    agent_name = agent.name

    async def _fanout(event: dict) -> None:
        await _broadcast_ark_async_event(user_id, sid_str, agent_name, event)

    conn.set_async_callback(_fanout)


async def _resolve_session_user_id(relay_session_id: uuid.UUID) -> str | None:
    """Look up the user_id that owns a Relay session."""
    from app.db.database import async_session
    from app.models.session import Session
    async with async_session() as db:
        result = await db.execute(
            select(Session.user_id).where(Session.session_id == relay_session_id)
        )
        return result.scalar_one_or_none()


async def _broadcast_ark_async_event(
    user_id: str, session_id_str: str, agent_name: str, event: dict,
) -> None:
    """Translate an ark async event into a Relay WS event and broadcast to all
    of the user's connected clients. Also persists agent-pushed files so they
    survive session reload."""
    from app.api.websocket import _broadcast_to_user

    etype = event.get("type")
    if etype == "file_available":
        path = event.get("path")
        size = event.get("size") or 0
        if not path:
            return
        # Persist as a File row so resume-after-disconnect shows the pill.
        file_id = await _persist_agent_shared_file(
            user_id=user_id,
            session_id_str=session_id_str,
            agent_name=agent_name,
            path=path,
            size=size,
        )
        await _broadcast_to_user(user_id, {
            "type": "agent_file",
            "payload": {
                "session_id": session_id_str,
                "agent_name": agent_name,
                "path": path,
                "description": event.get("description"),
                "size": size,
                "file_id": file_id,
            },
        })
    elif etype == "injected_message":
        text = event.get("text") or event.get("message") or ""
        if not text:
            return
        await _broadcast_to_user(user_id, {
            "type": "text",
            "payload": {"speaker": agent_name, "text": text},
        })


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
