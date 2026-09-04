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

from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.redis import cache_session_context, get_cached_context, invalidate_session_cache
from app.models.agent import Agent
from app.models.message import Message
from app.models.session import Session
from app.models.session_label import Label, SessionLabel
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

async def _operator_llm_config(db: AsyncSession) -> tuple[str, str, str | None, str | None]:
    """Return (provider, model, base_url, api_key) from the Operator agent's DB row."""
    op = await agent_manager.get_agent_by_name(db, "Operator")
    return (
        op.llm_provider if op else "openai",
        op.llm_model if op else "gpt-4o-mini",
        op.llm_base_url if op else None,
        op.llm_api_key if op else None,
    )


# ── Session CRUD ────────────────────────────────────────────────────────

async def get_session(db: AsyncSession, session_id: uuid.UUID) -> Session | None:
    result = await db.execute(
        select(Session).where(Session.session_id == session_id, Session.deleted_at.is_(None))
    )
    return result.scalar_one_or_none()


async def delete_session(db: AsyncSession, session_id: uuid.UUID) -> bool:
    """Soft-delete a session. Returns True if found and deleted."""
    session = await get_session(db, session_id)
    if not session:
        return False
    session.deleted_at = datetime.now(timezone.utc)
    await db.commit()
    await invalidate_session_cache(session_id)
    # No per-session ark connection to close — connections are now one per
    # (base_url, api_key) pair and outlive individual Relay sessions.
    return True


async def mark_session_unread(db: AsyncSession, session_id: uuid.UUID) -> None:
    """Mark a session as having unread messages."""
    session = await get_session(db, session_id)
    if session:
        session.has_unread = True
        await db.commit()


async def mark_session_read(db: AsyncSession, session_id: uuid.UUID) -> None:
    """Clear the unread flag on a session."""
    session = await get_session(db, session_id)
    if session and session.has_unread:
        session.has_unread = False
        await db.commit()


async def rename_session(
    db: AsyncSession, session_id: uuid.UUID, new_name: str
) -> Session | None:
    """Rename a session. Returns the session if found."""
    session = await get_session(db, session_id)
    if not session:
        return None
    session.name = new_name
    await db.commit()
    return session


async def get_session_labels(db: AsyncSession, session_id: uuid.UUID) -> list[str]:
    """Return label names for a session."""
    result = await db.execute(
        select(Label.name)
        .join(SessionLabel, Label.label_id == SessionLabel.label_id)
        .where(SessionLabel.session_id == session_id)
        .order_by(Label.name)
    )
    return [row[0] for row in result.all()]


async def set_session_labels(
    db: AsyncSession, session_id: uuid.UUID, user_id: str, label_names: list[str]
) -> list[str]:
    """Replace all labels on a session. Creates new Label rows as needed."""
    # Remove existing associations
    await db.execute(
        delete(SessionLabel).where(SessionLabel.session_id == session_id)
    )

    if not label_names:
        await db.commit()
        return []

    # Get-or-create labels
    final_labels: list[Label] = []
    for name in label_names:
        name = name.strip()
        if not name:
            continue
        result = await db.execute(
            select(Label).where(Label.user_id == user_id, Label.name == name)
        )
        label = result.scalar_one_or_none()
        if not label:
            label = Label(user_id=user_id, name=name)
            db.add(label)
            await db.flush()
        final_labels.append(label)

    # Create associations
    for label in final_labels:
        db.add(SessionLabel(session_id=session_id, label_id=label.label_id))

    await db.commit()
    return sorted(l.name for l in final_labels)


async def list_user_labels(db: AsyncSession, user_id: str = "default") -> list[dict]:
    """Return all labels for a user (for autocomplete)."""
    result = await db.execute(
        select(Label)
        .where(Label.user_id == user_id)
        .order_by(Label.name)
    )
    return [
        {"label_id": str(l.label_id), "name": l.name}
        for l in result.scalars().all()
    ]


async def list_session_facets(
    db: AsyncSession, user_id: str = "default",
) -> dict[str, list[str]]:
    """Return distinct labels and project_ids actually in use across the
    user's non-deleted sessions. Used to populate the filter dropdowns
    with values that appear on at least one existing session — no dead
    options — even when the sidebar's 20-most-recent cap hides the
    session where a rare label/project lives.
    """
    # Distinct label names attached to any of this user's sessions.
    label_rows = await db.execute(
        select(Label.name)
        .join(SessionLabel, Label.label_id == SessionLabel.label_id)
        .join(Session, SessionLabel.session_id == Session.session_id)
        .where(Session.user_id == user_id, Session.deleted_at.is_(None))
        .distinct()
    )
    labels = sorted([r[0] for r in label_rows.all() if r[0]])

    # Distinct project_ids used by this user's sessions.
    project_rows = await db.execute(
        select(Session.project_id)
        .where(
            Session.user_id == user_id,
            Session.deleted_at.is_(None),
            Session.project_id.is_not(None),
        )
        .distinct()
    )
    project_ids = sorted([str(r[0]) for r in project_rows.all() if r[0]])

    return {"labels": labels, "project_ids": project_ids}


async def has_user_messages(db: AsyncSession, session_id: uuid.UUID) -> bool:
    """Check whether a session has any user-sent messages."""
    result = await db.execute(
        select(func.count()).select_from(Message).where(
            Message.session_id == session_id, Message.role == "user"
        )
    )
    return (result.scalar() or 0) > 0


async def list_sessions(
    db: AsyncSession,
    user_id: str = "default",
    label_filter: str | None = None,
    project_filter: str | None = None,
    search: str | None = None,
) -> list[dict]:
    """Return sessions with agent names and labels for display.

    Default caps at 20 most-recent sessions. When any of `search`,
    `label_filter`, or `project_filter` is set, the cap is raised to
    500 so older sessions remain reachable.
    """
    query = (
        select(Session, Agent.name)
        .join(Agent, Session.agent_id == Agent.agent_id)
        .where(Session.user_id == user_id, Session.deleted_at.is_(None))
    )

    if label_filter:
        query = (
            query
            .join(SessionLabel, Session.session_id == SessionLabel.session_id)
            .join(Label, SessionLabel.label_id == Label.label_id)
            .where(Label.name == label_filter)
        )

    if project_filter:
        query = query.where(Session.project_id == project_filter)

    if search:
        pattern = f"%{search.lower()}%"
        query = query.where(
            or_(
                func.lower(Session.name).like(pattern),
                func.lower(Session.summary).like(pattern),
                func.lower(Agent.name).like(pattern),
            )
        )

    limit = 500 if (search or label_filter or project_filter) else 20
    query = query.order_by(Session.last_active.desc()).limit(limit)
    result = await db.execute(query)

    sessions = []
    for s, agent_name in result.all():
        labels = await get_session_labels(db, s.session_id)
        # Stringify provider_state values so the response is well-typed —
        # the client uses these (e.g. `ark` → ark session_id) for things
        # like configuring cron jobs.
        provider_state = {
            k: str(v) for k, v in (s.provider_state or {}).items() if v
        }
        sessions.append({
            "session_id": str(s.session_id),
            "agent_id": str(s.agent_id),
            "agent_name": agent_name,
            "status": s.status,
            "created_at": s.created_at.isoformat(),
            "last_active": s.last_active.isoformat(),
            "name": s.name,
            "summary": s.summary,
            "labels": labels,
            "has_unread": s.has_unread,
            "provider_state": provider_state,
            "project_id": s.project_id,
            "project_server_id": s.project_server_id,
        })
    return sessions


async def get_session_messages(
    db: AsyncSession, session_id: uuid.UUID, limit: int = 50
) -> list[dict]:
    """Return messages for a session, merged with any file attachments for
    the same session so the conversation replay includes upload pills and
    agent-shared files. Tries Redis cache first."""
    import time as _time
    _t0 = _time.perf_counter()
    cached = await get_cached_context(str(session_id))
    if cached is not None:
        logger.info(
            "[get_session_messages] sid=%s cache=HIT n=%d took=%.1fms",
            str(session_id)[:8], len(cached), (_time.perf_counter() - _t0) * 1000,
        )
        return cached
    _t_miss = _time.perf_counter()

    # Take the MOST RECENT `limit` messages, not the oldest — ordering ASC
    # with a limit lets the user's just-persisted turn fall off the slice
    # once the session crosses `limit` rows, so `_last_user_text` (and
    # downstream LLM context) loses the prompt entirely.
    result = await db.execute(
        select(Message)
        .where(Message.session_id == session_id)
        .order_by(Message.created_at.desc())
        .limit(limit)
    )
    rows = list(result.scalars().all())
    rows.reverse()  # back to chronological order for replay
    text_entries = [
        {
            "message_id": str(m.message_id),
            "role": m.role,
            "text_content": m.text_content,
            "created_at": m.created_at.isoformat(),
            # `metadata_` maps to the JSONB column on Message — emit it as
            # `metadata` for clients (e.g. Diagnostics view tokens).
            "metadata": m.metadata_ or {},
            "_ts": m.created_at,
        }
        for m in rows
    ]

    # Fold in file attachments as their own synthetic messages, ordered by
    # upload/share timestamp.
    from app.models.file import File as FileModel
    file_result = await db.execute(
        select(FileModel)
        .where(FileModel.session_id == session_id)
        .order_by(FileModel.created_at)
    )
    file_entries: list[dict] = []
    for f in file_result.scalars().all():
        # Agent-shared files go through the /v1/files/ark/... passthrough
        # because there isn't always a Relay-side file_id at the moment ark
        # pushes; user uploads use the file-id route.
        url: str
        if f.role == "agent" and f.storage_path.startswith("ark:"):
            # ark:<agent>:<workspace-path>
            rest = f.storage_path[len("ark:"):]
            agent_name, _, ark_path = rest.partition(":")
            url = f"/v1/files/ark/{agent_name}/{ark_path}"
        else:
            url = f"/v1/files/{f.file_id}/{f.filename}"
        file_entries.append({
            "role": f.role,
            "text_content": "",
            "created_at": f.created_at.isoformat(),
            "_ts": f.created_at,
            "attachments": [{
                "file_id": str(f.file_id),
                "filename": f.filename,
                "mime_type": f.mime_type,
                "size_bytes": f.size_bytes,
                "url": url,
            }],
        })

    messages = sorted(text_entries + file_entries, key=lambda e: e["_ts"])
    for m in messages:
        m.pop("_ts", None)
    await cache_session_context(str(session_id), messages)
    logger.info(
        "[get_session_messages] sid=%s cache=MISS n=%d msgs=%d files=%d took=%.1fms",
        str(session_id)[:8], len(messages), len(text_entries), len(file_entries),
        (_time.perf_counter() - _t_miss) * 1000,
    )
    return messages


async def _persist_message(
    db: AsyncSession, session_id: uuid.UUID, role: str, text: str,
    metadata: dict | None = None,
) -> Message:
    msg = Message(
        session_id=session_id, role=role, text_content=text,
        metadata_=metadata or {},
    )
    db.add(msg)
    session = await get_session(db, session_id)
    if session:
        session.last_active = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(msg)
    return msg


# ── Session lifecycle ───────────────────────────────────────────────────

async def _create_agent_session(
    db: AsyncSession, user_id: str, agent: Agent, labels: list[str] | None = None,
    project_id: str | None = None, project_server_id: str | None = None,
    name: str | None = None,
) -> Session:
    """Always create a fresh session for this user+agent pair. If
    `project_id` is provided, the session is bound to that ark project at
    creation time (immutable for life — matches ark's semantics). When
    `name` is provided, the session lands with that display name; the
    auto-name-after-2-turns logic gates on name being null so this is
    enough to override it."""
    session = Session(
        user_id=user_id, agent_id=agent.agent_id,
        project_id=project_id, project_server_id=project_server_id,
        name=name,
    )
    db.add(session)
    await db.commit()
    await db.refresh(session)

    if labels:
        await set_session_labels(db, session.session_id, user_id, labels)

    return session


async def pause_session(db: AsyncSession, session_id: uuid.UUID) -> str:
    """Pause a session and generate a summary.

    Returns "deleted" if the session had no user messages and was removed,
    "paused" if it was paused normally, or "not_found" if the session
    didn't exist or wasn't active.
    """
    session = await get_session(db, session_id)
    if not session or session.status not in ("active", "processing"):
        return "not_found"

    # If the user never sent a message, delete the session entirely
    if not await has_user_messages(db, session_id):
        await delete_session(db, session_id)
        return "deleted"

    session.status = "paused"
    await db.commit()

    # Ark connections are now per-server, not per-session — nothing to
    # close on session pause.

    # Generate summary async only if the session has no name yet
    if not session.name:
        import asyncio
        asyncio.ensure_future(_generate_summary_async(session_id, db))

    return "paused"


async def _generate_summary_async(session_id: uuid.UUID, db) -> None:
    """Generate a session summary in the background and update the DB."""
    try:
        session = await get_session(db, session_id)
        if not session:
            return
        messages = await get_session_messages(db, session_id)
        if not messages:
            return
        agent = await agent_manager.get_agent_by_id(db, session.agent_id)
        agent_name = agent.name if agent else "Agent"
        op_provider, op_model, op_base_url, op_api_key = await _operator_llm_config(db)
        session.summary = await generate_session_summary(
            messages, agent_name,
            provider=op_provider, model=op_model, base_url=op_base_url, api_key=op_api_key,
        )
        await db.commit()
    except Exception as exc:
        logger.warning("Background summary generation failed: %s", exc)


# ── Lobby message handling (Operator) ───────────────────────────────────

import re as _re

# Fast-path patterns for the most common lobby intent — "please connect
# me to <agent>". If the message matches one of these shapes AND the
# extracted name resolves to a known agent, we skip the ~1s Operator LLM
# round-trip and build the tool_call locally.
#
# Anything the patterns don't match (or that names an unknown agent, or
# includes labels/project qualifiers) falls through to the LLM.
_CONNECT_TRIGGER_RE = _re.compile(
    r"^\s*(?:please\s+)?"
    r"(?:"
    r"connect\s+me\s+to|"
    r"connect\s+to|"
    r"talk\s+to|"
    r"chat\s+with|"
    r"switch\s+to|"
    r"let\s+me\s+(?:talk|chat)\s+(?:to|with)|"
    r"start\s+a?\s*(?:chat|conversation)\s+with|"
    r"new\s+(?:chat|conversation)\s+with|"
    r"open\s+a?\s*(?:chat|conversation)\s+with"
    r")\s+(?P<name>.+?)\s*[.!?\s]*$",
    _re.IGNORECASE,
)


def _try_fast_connect(text: str, agents_raw: list) -> "OperatorResult | None":
    """Return an OperatorResult for `connect_to_agent` if the text is an
    unambiguous "connect me to <agent>" request against a known agent.
    Any hint of extra context (labels, project, "about …") falls through
    so the LLM can pick it up."""
    stripped = text.strip()

    # Reject messages that likely carry extra routing context — the LLM
    # is better at teasing out labels / projects from noise like
    # "connect me to Scribe about the docs" or "under the frontend label".
    lowered = stripped.lower()
    for tail_word in (" about ", " under ", " labeled ", " label ",
                      " in project ", " on project ", " re ", " re: "):
        if tail_word in lowered:
            return None

    # Try the trigger-phrase patterns first.
    candidate: str | None = None
    m = _CONNECT_TRIGGER_RE.match(stripped)
    if m:
        candidate = m.group("name").strip().strip(".!?,")

    # Bare agent name: exact match against a known agent's name (case-
    # insensitive). This handles quick voice inputs like just "Scribe".
    if not candidate and len(stripped.split()) <= 3:
        candidate = stripped.strip(".!?,")

    if not candidate:
        return None

    # Resolve to a known agent — exact case-insensitive, then close-fuzzy.
    candidate_lc = candidate.lower()
    matched: str | None = None
    for a in agents_raw:
        if a.name.lower() == candidate_lc and a.name.lower() != "operator":
            matched = a.name
            break
    if matched is None:
        names = [a.name for a in agents_raw if a.name.lower() != "operator"]
        close = difflib.get_close_matches(candidate, names, n=1, cutoff=0.85)
        if close:
            matched = close[0]

    if matched is None:
        return None

    logger.info(
        "[lobby.fast_connect] matched %r → agent=%s (skipping Operator LLM)",
        candidate, matched,
    )
    return OperatorResult(
        tool_call="connect_to_agent",
        tool_args={"agent_name": matched},
    )


async def handle_lobby_message(
    db: AsyncSession, user_id: str, text: str, lobby_history: list[dict] | None = None
) -> list[dict]:
    """Process a message in the lobby. Operator responses are ephemeral (not persisted).

    Tries the LLM operator first. Falls back to keyword matching if no API key
    is configured or the LLM call fails.
    """
    if lobby_history is None:
        lobby_history = []

    # Build context for the LLM. Each ark agent is tagged with its ark
    # `server_id` so the operator can match agents to projects on the same
    # backend when binding a session.
    from app.services.projects import _ark_servers, list_all_projects
    from app.services.llm.ark import _server_id_for as _ark_server_id_for

    import time as _time_hlm
    _t0 = _time_hlm.perf_counter()

    def _lap(label: str) -> None:
        nonlocal _t0
        now = _time_hlm.perf_counter()
        logger.info("[lobby.hlm] %s: %.1fms", label, (now - _t0) * 1000)
        _t0 = now

    agents_raw = await agent_manager.list_agents(db)
    _lap(f"list_agents(n={len(agents_raw)})")
    agents_ctx = []
    for a in agents_raw:
        health = agent_health.get_status(a.agent_id)
        ark_sid: str | None = None
        if a.llm_provider == "ark":
            base_url, api_key = await agent_manager.resolve_llm_config(a)
            if base_url:
                ark_sid = _ark_server_id_for(base_url.rstrip("/"), api_key)
        agents_ctx.append({
            "name": a.name,
            "persona_prompt": a.persona_prompt,
            "status": health.status,
            "status_message": health.message,
            "ark_server_id": ark_sid,
        })
    _lap("build_agents_ctx (per-agent resolve_llm_config)")
    sessions_ctx = await list_sessions(db, user_id)
    _lap(f"list_sessions(n={len(sessions_ctx)})")
    projects_ctx: list[dict] = []
    ark_server_ids: list[str] = []
    try:
        projects_ctx = await list_all_projects(db)
        ark_server_ids = [sid for sid, _, _ in await _ark_servers(db)]
    except Exception:
        # Operator can still function without project context — log and move on.
        logger.exception("Failed to load project context for operator")
    _lap(f"list_all_projects+ark_servers (n_projects={len(projects_ctx)}, n_servers={len(ark_server_ids)})")

    # Fast path: obvious "connect me to <agent>" phrasings skip the LLM
    # entirely. Anything ambiguous still goes through the operator.
    fast = _try_fast_connect(text, agents_raw)
    if fast is not None:
        _lap("fast_connect(HIT)")
        r = await _handle_llm_result(db, user_id, fast, lobby_history)
        _lap(f"_handle_llm_result(fast, n_events={len(r)})")
        return r

    op_provider, op_model, op_base_url, op_api_key = await _operator_llm_config(db)
    _lap("_operator_llm_config")

    try:
        result = await call_operator(
            text, agents_ctx, sessions_ctx, lobby_history,
            projects=projects_ctx, ark_servers=ark_server_ids,
            provider=op_provider, model=op_model, base_url=op_base_url, api_key=op_api_key,
        )
    except Exception as exc:
        logger.exception("Operator LLM call failed, falling back to keyword matching: %s", exc)
        result = OperatorResult()  # Fall back to keyword matching
    _lap(f"call_operator (provider={op_provider}, model={op_model}, tool_call={result.tool_call})")

    # If LLM returned a result, process it
    if result.tool_call or result.text:
        logger.info("Using LLM operator result (tool_call=%s)", result.tool_call)
        r = await _handle_llm_result(db, user_id, result, lobby_history)
        _lap(f"_handle_llm_result(tool_call={result.tool_call}, n_events={len(r)})")
        return r

    # Fallback: keyword-based matching
    logger.info("Using keyword fallback for: %s", text[:60])
    r = await _handle_lobby_keyword(db, user_id, text, agents_raw, sessions_ctx)
    _lap(f"_handle_lobby_keyword(n_events={len(r)})")
    return r


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
        labels = result.tool_args.get("labels")
        project_name = result.tool_args.get("project_name")
        _append_tool_result(lobby_history, result, f"Connected to {agent_name}")
        if result.text:
            events.append(_text_event("operator", result.text))
        events.extend(await _execute_handoff(
            db, user_id, agent_name, labels=labels, project_name=project_name,
        ))
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

    if result.tool_call == "create_project":
        from app.services.projects import create_project_via_ark

        name = (result.tool_args.get("name") or "").strip()
        if not name:
            _append_tool_result(lobby_history, result, "Refused: missing project name")
            return [_lobby_state_event(), _text_event("operator", "Need a project name.")]
        try:
            created = await create_project_via_ark(
                db,
                server_id=result.tool_args.get("ark_server_id"),
                name=name,
                description=result.tool_args.get("description"),
                project_context=result.tool_args.get("project_context"),
            )
        except RuntimeError as exc:
            _append_tool_result(lobby_history, result, f"Refused: {exc}")
            return [
                _lobby_state_event(),
                _text_event("operator", f"Couldn't create the project: {exc}"),
            ]
        _append_tool_result(
            lobby_history, result,
            f"Created project {created.get('name')} on ark:{created.get('server_id')}",
        )
        reply = result.text or f"Created project '{created.get('name')}'."
        return [_lobby_state_event(), _text_event("operator", reply)]

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
    db: AsyncSession, user_id: str, agent_name: str | None,
    labels: list[str] | None = None, project_name: str | None = None,
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

    # Resolve the optional project binding — only valid when:
    # (a) the agent is ark-backed, and
    # (b) the project lives on the *same* ark server as the agent.
    # Otherwise we drop the binding silently and prepend a one-phrase notice
    # to the operator's reply so the user understands what happened.
    project_id: str | None = None
    project_server_id: str | None = None
    project_warning: str | None = None
    if project_name:
        from app.services.projects import resolve_project_by_name
        project = await resolve_project_by_name(db, project_name)
        if project is None:
            project_warning = f"Couldn't find a project named '{project_name}' — connecting without binding."
        elif agent.llm_provider != "ark":
            project_warning = f"{agent.name} isn't an ark agent, so I can't bind it to the project."
        else:
            base_url, api_key = await agent_manager.resolve_llm_config(agent)
            from app.services.llm.ark import _server_id_for as _ark_sid
            agent_sid = _ark_sid((base_url or "").rstrip("/"), api_key) if base_url else None
            if agent_sid != project.get("server_id"):
                project_warning = (
                    f"{agent.name} is on a different ark backend than '{project_name}' — "
                    "connecting without the project binding."
                )
            else:
                project_id = project.get("id")
                project_server_id = project.get("server_id")

    health = agent_health.get_status(agent.agent_id)
    session = await _create_agent_session(
        db, user_id, agent, labels=labels,
        project_id=project_id, project_server_id=project_server_id,
    )

    confirm = operator_connect_message(agent.name)
    greeting = "Hello. Where should we start?"
    await _persist_message(db, session.session_id, "agent", greeting)

    session_labels = await get_session_labels(db, session.session_id)

    events: list[dict] = [_text_event("operator", confirm)]
    if project_warning:
        events.append(_text_event("operator", project_warning))
    if health.status == "error":
        events.append(_text_event(
            "operator",
            f"Warning: {agent.name} is currently experiencing issues "
            f"({health.message}). Connecting you anyway, but responses may not work.",
        ))
    events.extend([
        _handoff_event("operator", agent.name),
        _session_entered_event(session, agent.name, session_labels),
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

    # In-session message: check ONLY for the exact-string "operator"
    # disconnect escape. The CONNECT regex (`connect\s+(?:me\s+)?(?:to\s+)?(\w+)`)
    # was also being matched here, but it's far too permissive for
    # in-session text — "we need to connect to a broader audience"
    # shouldn't yank the user out of the session they're in. Lobby
    # routing intents only apply in the lobby.
    intent = parse_intent(text)

    if intent.intent == Intent.DISCONNECT:
        await pause_session(db, session_id)
        reply = operator_disconnect_message()
        return [
            _handoff_event("agent", "operator"),
            _session_left_event(
                session,
                reason="intent_disconnect",
                detail={"matched_text": text},
            ),
            _lobby_state_event(),
            _text_event("operator", reply),
        ]

    # Normal agent conversation
    await _persist_message(db, session_id, "user", text)
    await invalidate_session_cache(str(session_id))

    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    if not agent:
        return [{"type": "error", "payload": {"message": "Agent not found"}}]

    context = await get_session_messages(db, session_id)
    response_text = await agent_manager.generate_response(agent, text, context, voice_instructions, session_id=session_id)
    await _persist_message(db, session_id, "agent", response_text)
    await invalidate_session_cache(str(session_id))

    # Auto-name the session after 4 turns (2 user + 2 agent)
    if session.name is None:
        msgs = await get_session_messages(db, session_id)
        user_turn_count = sum(1 for m in msgs if m["role"] == "user")
        if user_turn_count >= 2:
            try:
                transcript = "\n".join(f"{m['role']}: {m['text_content'][:150]}" for m in msgs[-6:])
                op_provider, op_model, op_base_url, op_api_key = await _operator_llm_config(db)
                name = await generate_session_name(
                    transcript, "", agent.name,
                    provider=op_provider, model=op_model, base_url=op_base_url, api_key=op_api_key,
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

    # In-session: only the exact-string "operator" disconnect escape is
    # honored. See the matching note in `handle_session_message`.
    intent = parse_intent(text)

    if intent.intent == Intent.DISCONNECT:
        await pause_session(db, session_id)
        reply = operator_disconnect_message()
        yield _handoff_event("agent", "operator")
        yield _session_left_event(
            session,
            reason="intent_disconnect",
            detail={"matched_text": text},
        )
        yield _lobby_state_event()
        yield _text_event("operator", reply)
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
    response_meta: dict = {}
    async for chunk in agent_manager.generate_response_stream(agent, text, context, voice_instructions, session_id=session_id):
        if isinstance(chunk, agent_manager.ResponseMeta):
            response_meta = chunk.metadata
            continue
        # Activity dicts flow from the ark provider when it observes
        # thinking / tool_call / tool_result events during a turn.
        # Forward as a dedicated `agent_activity` event so the client
        # can render its "current activity" strip; not persisted.
        if isinstance(chunk, dict) and "__activity__" in chunk:
            yield {
                "type": "agent_activity",
                "payload": {
                    "session_id": str(session_id),
                    "speaker": agent.name,
                    "kind": chunk["__activity__"],
                    "detail": chunk.get("payload") or {},
                },
            }
            continue
        # Ark provider surfaces a fatal RunError this way. Persist as a
        # `role="error"` marker so history renders a divider on replay,
        # emit a dedicated WS event so the client can sweep any
        # in-flight streaming bubble to interrupted and drop the
        # divider inline, then terminate the turn cleanly.
        if isinstance(chunk, dict) and "__error__" in chunk:
            err = chunk["__error__"]
            code = str(err.get("code") or "other")
            message = str(err.get("message") or "")
            marker_text = f"{code}: {message}" if message else code
            await _persist_message(
                db, session_id, "error", marker_text,
                metadata={"code": code, "message": message},
            )
            await invalidate_session_cache(str(session_id))
            yield {
                "type": "session_error",
                "payload": {
                    "session_id": str(session_id),
                    "agent_name": agent.name,
                    "code": code,
                    "message": message,
                    "marker_text": marker_text,
                },
            }
            yield _session_state_event(session, agent.name, "ready")
            return
        full_response += chunk
        yield {"type": "text_delta", "payload": {"speaker": agent.name, "delta": chunk}}

    text_done_payload: dict = {"speaker": agent.name, "text": full_response}
    if response_meta:
        text_done_payload["metadata"] = response_meta
    yield {"type": "text_done", "payload": text_done_payload}
    yield _session_state_event(session, agent.name, "ready")

    # Persist complete response
    await _persist_message(db, session_id, "agent", full_response, metadata=response_meta or None)
    await invalidate_session_cache(str(session_id))

    # Auto-name the session after 4 turns (2 user + 2 agent)
    if session.name is None:
        msgs = await get_session_messages(db, session_id)
        user_turn_count = sum(1 for m in msgs if m["role"] == "user")
        if user_turn_count >= 2:
            try:
                transcript = "\n".join(f"{m['role']}: {m['text_content'][:150]}" for m in msgs[-6:])
                op_provider, op_model, op_base_url, op_api_key = await _operator_llm_config(db)
                name = await generate_session_name(
                    transcript, "", agent.name,
                    provider=op_provider, model=op_model, base_url=op_base_url, api_key=op_api_key,
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


def _session_entered_event(session: Session, agent_name: str, labels: list[str] | None = None) -> dict:
    return {
        "type": "session_entered",
        "payload": {
            "session_id": str(session.session_id),
            "agent_name": agent_name,
            "labels": labels or [],
        },
    }


def _session_left_event(
    session: Session, *, reason: str, detail: dict | None = None,
) -> dict:
    """Build the wire frame for a session_left event.

    Every emission carries a structured `reason` so the client's activity
    log can show exactly what made it exit — particularly useful when the
    regex-based intent matcher picks something up the user didn't intend
    as a command (e.g. "we need to connect to a broader audience" hits
    `Intent.CONNECT` and ejects them). When applicable, `detail` carries
    the original text + the matched intent target.
    """
    payload: dict = {
        "session_id": str(session.session_id),
        "reason": reason,
    }
    if detail:
        payload["detail"] = detail
    return {"type": "session_left", "payload": payload}
