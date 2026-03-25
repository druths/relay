"""
Conversation Manager — the orchestrator.

Two entry points:
  handle_lobby_message  — user is in the lobby talking to the Operator (ephemeral)
  handle_session_message — user is inside an agent session (persistent)
"""

from __future__ import annotations

import difflib
import logging
import uuid
from collections.abc import AsyncGenerator
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.redis import cache_session_context, get_cached_context, invalidate_session_cache
from app.models.agent import Agent
from app.models.message import Message
from app.models.session import Session
from app.services import agent_manager
from app.services.operator import (
    Intent,
    operator_connect_message,
    operator_disconnect_message,
    operator_list_agents,
    operator_not_found,
    parse_intent,
)
from app.services import agent_health
from app.services.operator_llm import OperatorResult, call_operator
from app.services.session_llm import generate_session_name, generate_session_summary


# ── Operator config helper ──────────────────────────────────────────────

async def _operator_llm_config(db: AsyncSession) -> tuple[str, str | None, str | None]:
    """Return (model, base_url, api_key) from the Operator agent's DB row."""
    op = await agent_manager.get_agent_by_name(db, "Operator")
    return (
        op.llm_model if op else "gpt-4o-mini",
        op.llm_base_url if op else None,
        op.llm_api_key if op else None,
    )


# ── Session CRUD ────────────────────────────────────────────────────────

async def get_session(db: AsyncSession, session_id: uuid.UUID) -> Session | None:
    result = await db.execute(
        select(Session).where(Session.session_id == session_id)
    )
    return result.scalar_one_or_none()


async def list_sessions(db: AsyncSession, user_id: str = "default") -> list[dict]:
    """Return sessions with agent names for display."""
    result = await db.execute(
        select(Session, Agent.name)
        .join(Agent, Session.agent_id == Agent.agent_id)
        .where(Session.user_id == user_id)
        .order_by(Session.last_active.desc())
        .limit(20)
    )
    return [
        {
            "session_id": str(s.session_id),
            "agent_id": str(s.agent_id),
            "agent_name": agent_name,
            "status": s.status,
            "created_at": s.created_at.isoformat(),
            "last_active": s.last_active.isoformat(),
            "name": s.name,
            "summary": s.summary,
        }
        for s, agent_name in result.all()
    ]


async def get_session_messages(
    db: AsyncSession, session_id: uuid.UUID, limit: int = 50
) -> list[dict]:
    """Return messages for a session, trying Redis cache first."""
    cached = await get_cached_context(str(session_id))
    if cached is not None:
        return cached

    result = await db.execute(
        select(Message)
        .where(Message.session_id == session_id)
        .order_by(Message.created_at)
        .limit(limit)
    )
    messages = [
        {
            "message_id": str(m.message_id),
            "role": m.role,
            "text_content": m.text_content,
            "created_at": m.created_at.isoformat(),
        }
        for m in result.scalars().all()
    ]
    await cache_session_context(str(session_id), messages)
    return messages


async def _persist_message(
    db: AsyncSession, session_id: uuid.UUID, role: str, text: str
) -> Message:
    msg = Message(session_id=session_id, role=role, text_content=text)
    db.add(msg)
    session = await get_session(db, session_id)
    if session:
        session.last_active = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(msg)
    return msg


# ── Session lifecycle ───────────────────────────────────────────────────

async def _create_agent_session(
    db: AsyncSession, user_id: str, agent: Agent
) -> Session:
    """Always create a fresh session for this user+agent pair."""
    session = Session(user_id=user_id, agent_id=agent.agent_id)
    db.add(session)
    await db.commit()
    await db.refresh(session)
    return session


async def pause_session(db: AsyncSession, session_id: uuid.UUID) -> None:
    """Pause a session and generate a summary."""
    session = await get_session(db, session_id)
    if session and session.status == "active":
        try:
            messages = await get_session_messages(db, session_id)
            if messages:
                agent = await agent_manager.get_agent_by_id(db, session.agent_id)
                agent_name = agent.name if agent else "Agent"
                op_model, op_base_url, op_api_key = await _operator_llm_config(db)
                session.summary = await generate_session_summary(
                    messages, agent_name,
                    model=op_model, base_url=op_base_url, api_key=op_api_key,
                )
        except Exception as exc:
            logger.warning("Failed to generate session summary: %s", exc)

        session.status = "paused"
        await db.commit()


# ── Lobby message handling (Operator) ───────────────────────────────────

async def handle_lobby_message(
    db: AsyncSession, user_id: str, text: str, lobby_history: list[dict] | None = None
) -> list[dict]:
    """Process a message in the lobby. Operator responses are ephemeral (not persisted).

    Tries the LLM operator first. Falls back to keyword matching if no API key
    is configured or the LLM call fails.
    """
    if lobby_history is None:
        lobby_history = []

    # Build context for the LLM
    agents_raw = await agent_manager.list_agents(db)
    agents_ctx = []
    for a in agents_raw:
        health = agent_health.get_status(a.agent_id)
        agents_ctx.append({
            "name": a.name,
            "persona_prompt": a.persona_prompt,
            "status": health.status,
            "status_message": health.message,
        })
    sessions_ctx = await list_sessions(db, user_id)

    op_model, op_base_url, op_api_key = await _operator_llm_config(db)

    try:
        result = await call_operator(
            text, agents_ctx, sessions_ctx, lobby_history,
            model=op_model, base_url=op_base_url, api_key=op_api_key,
        )
    except Exception as exc:
        logger.exception("Operator LLM call failed, falling back to keyword matching: %s", exc)
        result = OperatorResult()  # Fall back to keyword matching

    # If LLM returned a result, process it
    if result.tool_call or result.text:
        logger.info("Using LLM operator result (tool_call=%s)", result.tool_call)
        return await _handle_llm_result(db, user_id, result, lobby_history)

    # Fallback: keyword-based matching
    logger.info("Using keyword fallback for: %s", text[:60])
    return await _handle_lobby_keyword(db, user_id, text, agents_raw, sessions_ctx)


def _append_tool_result(lobby_history: list[dict], result: OperatorResult, content: str) -> None:
    """Append a tool-result message to lobby history so the next LLM call has valid message ordering.

    OpenAI requires that an assistant message with tool_calls is followed by
    tool-role messages for each call_id.
    """
    if result.assistant_message and result.assistant_message.get("tool_calls"):
        for tc in result.assistant_message["tool_calls"]:
            lobby_history.append({
                "role": "tool",
                "tool_call_id": tc["id"],
                "content": content,
            })


async def _handle_llm_result(
    db: AsyncSession, user_id: str, result: OperatorResult, lobby_history: list[dict]
) -> list[dict]:
    """Process an OperatorResult from the LLM."""
    events: list[dict] = []

    # Track the assistant message in lobby history
    if result.assistant_message:
        lobby_history.append(result.assistant_message)

    if result.tool_call == "connect_to_agent":
        agent_name = result.tool_args.get("agent_name")
        _append_tool_result(lobby_history, result, f"Connected to {agent_name}")
        if result.text:
            events.append(_text_event("operator", result.text))
        events.extend(await _execute_handoff(db, user_id, agent_name))
        return events

    if result.tool_call == "resume_session":
        session_id = result.tool_args.get("session_id")
        _append_tool_result(lobby_history, result, f"Resumed session {session_id}")
        if result.text:
            events.append(_text_event("operator", result.text))
        events.append({
            "type": "resume_via_lobby",
            "payload": {"session_id": session_id},
        })
        return events

    # No tool call — just a conversational reply
    if result.text:
        return [_lobby_state_event(), _text_event("operator", result.text)]

    return [_lobby_state_event()]


async def _handle_lobby_keyword(
    db: AsyncSession,
    user_id: str,
    text: str,
    agents_raw: list,
    sessions_ctx: list[dict],
) -> list[dict]:
    """Keyword-based fallback when the LLM is not available."""
    intent = parse_intent(text)

    if intent.intent in (Intent.CONNECT, Intent.RESUME):
        return await _execute_handoff(db, user_id, intent.target_agent)

    if intent.intent == Intent.LIST_AGENTS:
        names = [a.name for a in agents_raw]
        reply = operator_list_agents(names)
        return [_lobby_state_event(), _text_event("operator", reply)]

    if intent.intent == Intent.LIST_SESSIONS:
        if not sessions_ctx:
            reply = "You don't have any sessions yet."
        else:
            lines = []
            for s in sessions_ctx:
                name = s.get("name") or "(unnamed)"
                line = f"- {s['agent_name']}: {name} ({s['status']}, last active {s['last_active'][:16]})"
                if s.get("summary"):
                    line += f"\n  {s['summary']}"
                lines.append(line)
            reply = "Here are your recent sessions:\n" + "\n".join(lines)
        return [_lobby_state_event(), _text_event("operator", reply)]

    reply = (
        "I'm the Operator. I can connect you to an agent — "
        "just say something like 'connect me to Vanto', or ask 'who are the available agents?'."
    )
    return [_lobby_state_event(), _text_event("operator", reply)]


async def _execute_handoff(
    db: AsyncSession, user_id: str, agent_name: str | None
) -> list[dict]:
    if not agent_name:
        reply = "Which agent?"
        return [_lobby_state_event(), _text_event("operator", reply)]

    agent = await agent_manager.get_agent_by_name(db, agent_name)
    if not agent:
        # Fuzzy match — handles STT misspellings (e.g. "vanta" → "Vanto")
        all_agents = await agent_manager.list_agents(db)
        all_names = [a.name for a in all_agents if a.name.lower() != "operator"]
        matches = difflib.get_close_matches(agent_name, all_names, n=1, cutoff=0.55)
        if matches:
            agent = next((a for a in all_agents if a.name == matches[0]), None)
    if not agent:
        reply = operator_not_found(agent_name)
        return [_lobby_state_event(), _text_event("operator", reply)]

    health = agent_health.get_status(agent.agent_id)
    session = await _create_agent_session(db, user_id, agent)

    confirm = operator_connect_message(agent.name)
    greeting = f"Hi, I'm {agent.name}. How can I help you?"
    await _persist_message(db, session.session_id, "agent", greeting)

    events: list[dict] = [_text_event("operator", confirm)]
    if health.status == "error":
        events.append(_text_event(
            "operator",
            f"Warning: {agent.name} is currently experiencing issues "
            f"({health.message}). Connecting you anyway, but responses may not work.",
        ))
    events.extend([
        _handoff_event("operator", agent.name),
        _session_entered_event(session, agent.name),
        _text_event(agent.name, greeting),
    ])

    await invalidate_session_cache(str(session.session_id))
    return events


# ── Agent session message handling ──────────────────────────────────────

async def handle_session_message(
    db: AsyncSession, session_id: uuid.UUID, text: str,
    voice_instructions: str | None = None,
) -> list[dict]:
    """Process a message inside an agent session. Messages are persisted."""
    session = await get_session(db, session_id)
    if not session:
        return [{"type": "error", "payload": {"message": "Session not found"}}]

    # Check for disconnect / switch intent before persisting
    intent = parse_intent(text)

    if intent.intent == Intent.DISCONNECT:
        await pause_session(db, session_id)
        reply = operator_disconnect_message()
        return [
            _handoff_event("agent", "operator"),
            _session_left_event(session),
            _lobby_state_event(),
            _text_event("operator", reply),
        ]

    if intent.intent == Intent.CONNECT:
        # Switch agents: pause current, tell WS handler to re-route through lobby
        await pause_session(db, session_id)
        return [
            _session_left_event(session),
            {"type": "lobby_redirect", "payload": {"text": text}},
        ]

    # Normal agent conversation
    await _persist_message(db, session_id, "user", text)
    await invalidate_session_cache(str(session_id))

    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    if not agent:
        return [{"type": "error", "payload": {"message": "Agent not found"}}]

    context = await get_session_messages(db, session_id)
    response_text = await agent_manager.generate_response(agent, text, context, voice_instructions)
    await _persist_message(db, session_id, "agent", response_text)
    await invalidate_session_cache(str(session_id))

    # Auto-name the session after the first user exchange
    if session.name is None:
        try:
            op_model, op_base_url, op_api_key = await _operator_llm_config(db)
            name = await generate_session_name(
                text, response_text, agent.name,
                model=op_model, base_url=op_base_url, api_key=op_api_key,
            )
            session.name = name
            await db.commit()
        except Exception as exc:
            logger.warning("Failed to generate session name: %s", exc)

    events: list[dict] = [
        _session_state_event(session, agent.name),
        _text_event(agent.name, response_text),
    ]

    if session.name:
        events.append({
            "type": "session_named",
            "payload": {
                "session_id": str(session.session_id),
                "name": session.name,
            },
        })

    return events


# ── Streaming agent session message handling ───────────────────────────

async def handle_session_message_stream(
    db: AsyncSession, session_id: uuid.UUID, text: str,
    voice_instructions: str | None = None,
) -> AsyncGenerator[dict, None]:
    """Process a message inside an agent session, streaming the response."""
    session = await get_session(db, session_id)
    if not session:
        yield {"type": "error", "payload": {"message": "Session not found"}}
        return

    # Check for disconnect / switch intent before persisting
    intent = parse_intent(text)

    if intent.intent == Intent.DISCONNECT:
        await pause_session(db, session_id)
        reply = operator_disconnect_message()
        yield _handoff_event("agent", "operator")
        yield _session_left_event(session)
        yield _lobby_state_event()
        yield _text_event("operator", reply)
        return

    if intent.intent == Intent.CONNECT:
        await pause_session(db, session_id)
        yield _session_left_event(session)
        yield {"type": "lobby_redirect", "payload": {"text": text}}
        return

    # Normal agent conversation
    await _persist_message(db, session_id, "user", text)
    await invalidate_session_cache(str(session_id))

    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    if not agent:
        yield {"type": "error", "payload": {"message": "Agent not found"}}
        return

    context = await get_session_messages(db, session_id)

    yield _session_state_event(session, agent.name, "processing")
    yield {"type": "text_start", "payload": {"speaker": agent.name}}

    full_response = ""
    async for chunk in agent_manager.generate_response_stream(agent, text, context, voice_instructions):
        full_response += chunk
        yield {"type": "text_delta", "payload": {"speaker": agent.name, "delta": chunk}}

    yield {"type": "text_done", "payload": {"speaker": agent.name, "text": full_response}}
    yield _session_state_event(session, agent.name, "ready")

    # Persist complete response
    await _persist_message(db, session_id, "agent", full_response)
    await invalidate_session_cache(str(session_id))

    # Auto-name the session after the first user exchange
    if session.name is None:
        try:
            op_model, op_base_url, op_api_key = await _operator_llm_config(db)
            name = await generate_session_name(
                text, full_response, agent.name,
                model=op_model, base_url=op_base_url, api_key=op_api_key,
            )
            session.name = name
            await db.commit()
            yield {
                "type": "session_named",
                "payload": {
                    "session_id": str(session.session_id),
                    "name": name,
                },
            }
        except Exception as exc:
            logger.warning("Failed to generate session name: %s", exc)


# ── Event builders ──────────────────────────────────────────────────────

def _lobby_state_event() -> dict:
    return {
        "type": "state_update",
        "payload": {
            "active_speaker": "operator",
            "status": "ready",
            "session_id": None,
        },
    }


def _session_state_event(session: Session, speaker: str, status: str = "ready") -> dict:
    return {
        "type": "state_update",
        "payload": {
            "active_speaker": speaker,
            "status": status,
            "session_id": str(session.session_id),
        },
    }


def _text_event(speaker: str, text: str) -> dict:
    return {
        "type": "text",
        "payload": {
            "speaker": speaker,
            "text": text,
        },
    }


def _handoff_event(from_: str, to: str) -> dict:
    return {
        "type": "handoff",
        "payload": {
            "from": str(from_),
            "to": to,
            "play_earcon": True,
        },
    }


def _session_entered_event(session: Session, agent_name: str) -> dict:
    return {
        "type": "session_entered",
        "payload": {
            "session_id": str(session.session_id),
            "agent_name": agent_name,
        },
    }


def _session_left_event(session: Session) -> dict:
    return {
        "type": "session_left",
        "payload": {
            "session_id": str(session.session_id),
        },
    }
