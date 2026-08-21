"""REST endpoints for session management."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.services.conversation_manager import (
    delete_session,
    get_session,
    get_session_labels,
    get_session_messages,
    list_session_facets,
    list_sessions,
    list_user_labels,
    rename_session,
    set_session_labels,
)

from app.api.auth import get_current_user

router = APIRouter(
    prefix="/v1/sessions",
    tags=["sessions"],
    dependencies=[Depends(get_current_user)],
)

labels_router = APIRouter(
    prefix="/v1/labels",
    tags=["labels"],
    dependencies=[Depends(get_current_user)],
)


class SessionOut(BaseModel):
    session_id: str
    agent_id: str
    agent_name: str
    status: str
    created_at: str
    last_active: str
    name: str | None = None
    summary: str | None = None
    labels: list[str] = []
    has_unread: bool = False
    # External-system session identifiers, keyed by provider. For ark this
    # is the server-side session id that tools like `post_to_session` and
    # cron entries reference.
    provider_state: dict[str, str] = {}
    # ark project binding. `project_id` is the ark UUID; `project_server_id`
    # disambiguates across multiple ark servers. Both null for sessions not
    # bound to a project. Clients resolve `project_name` via `GET /v1/projects`.
    project_id: str | None = None
    project_server_id: str | None = None


class MessageOut(BaseModel):
    message_id: str
    role: str
    text_content: str
    created_at: str


class SessionRenameIn(BaseModel):
    name: str


class SessionLabelsIn(BaseModel):
    labels: list[str]


class SessionProjectIn(BaseModel):
    """Body for `PATCH /v1/sessions/{id}/project`. `project_id: null`
    detaches the session from any project; a uuid reassigns (or first-time
    assigns) to that project on the same ark server the session's agent
    is bound to. `project_server_id` is derived from the session's agent —
    ark rejects cross-server binds with 404, so accepting it from the
    client would just give us a worse error message."""
    project_id: str | None = None


class LabelOut(BaseModel):
    label_id: str
    name: str


class SessionFacetsOut(BaseModel):
    """Distinct labels + project_ids actually in use across the user's
    sessions. Powers the sidebar's Project + Label filter dropdowns so
    they surface every value in use, not just what's in the loaded
    20-most-recent slice."""
    labels: list[str]
    project_ids: list[str]


@router.get("/facets", response_model=SessionFacetsOut)
async def get_session_facets(
    user_id: str = "default", db: AsyncSession = Depends(get_db),
):
    facets = await list_session_facets(db, user_id)
    return SessionFacetsOut(**facets)


@router.get("", response_model=list[SessionOut])
async def get_sessions(
    user_id: str = "default",
    label: str | None = Query(None, description="Filter sessions by label name"),
    project: str | None = Query(None, description="Filter sessions by ark project_id"),
    search: str | None = Query(None, description="Search by session name, summary, or agent name"),
    db: AsyncSession = Depends(get_db),
):
    sessions = await list_sessions(
        db, user_id, label_filter=label, project_filter=project, search=search,
    )
    return [SessionOut(**s) for s in sessions]


class SessionCreateIn(BaseModel):
    agent_id: str
    project_id: str | None = None
    # Required when `project_id` is set and multiple ark servers are in play —
    # mirrors the projects-passthrough scoping. Stored on the row so future
    # operations on the session can locate the right ark.
    project_server_id: str | None = None
    labels: list[str] | None = None
    # Optional display name. When set, the auto-name-after-2-turns logic in
    # `handle_session_message_stream` is suppressed (it gates on name being
    # null), so user intent is preserved.
    name: str | None = None


@router.post("", response_model=SessionOut, status_code=201)
async def create_session_endpoint(
    body: SessionCreateIn,
    user_id: str = "default",
    db: AsyncSession = Depends(get_db),
):
    """Create a Relay session with an explicit agent and optional project
    binding. The ark-side session is NOT created here — it's lazily opened
    on the first user message, where the binding flows through to ark."""
    from app.services import agent_manager
    from app.services.conversation_manager import _create_agent_session
    import uuid as _uuid

    try:
        aid = _uuid.UUID(body.agent_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid agent_id")
    agent = await agent_manager.get_agent_by_id(db, aid)
    if agent is None:
        raise HTTPException(status_code=404, detail="Agent not found")
    if body.project_id and agent.llm_provider != "ark":
        raise HTTPException(
            status_code=400,
            detail="Only ark agents can be bound to projects",
        )

    session = await _create_agent_session(
        db, user_id, agent,
        labels=body.labels,
        project_id=body.project_id,
        project_server_id=body.project_server_id,
        name=(body.name or "").strip() or None,
    )
    labels = await get_session_labels(db, session.session_id)
    return SessionOut(
        session_id=str(session.session_id),
        agent_id=str(session.agent_id),
        agent_name=agent.name,
        status=session.status,
        created_at=session.created_at.isoformat(),
        last_active=session.last_active.isoformat(),
        name=session.name,
        summary=session.summary,
        labels=labels,
        project_id=session.project_id,
        project_server_id=session.project_server_id,
    )


@router.patch("/{session_id}", response_model=SessionOut)
async def rename_session_endpoint(
    session_id: uuid.UUID,
    body: SessionRenameIn,
    user_id: str = "default",
    db: AsyncSession = Depends(get_db),
):
    session = await rename_session(db, session_id, body.name)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    labels = await get_session_labels(db, session_id)
    from app.services import agent_manager
    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    return SessionOut(
        session_id=str(session.session_id),
        agent_id=str(session.agent_id),
        agent_name=agent.name if agent else "Unknown",
        status=session.status,
        created_at=session.created_at.isoformat(),
        last_active=session.last_active.isoformat(),
        name=session.name,
        summary=session.summary,
        labels=labels,
        project_id=session.project_id,
        project_server_id=session.project_server_id,
    )


@router.delete("/{session_id}", status_code=204)
async def delete_session_endpoint(
    session_id: uuid.UUID, db: AsyncSession = Depends(get_db)
):
    found = await delete_session(db, session_id)
    if not found:
        raise HTTPException(status_code=404, detail="Session not found")


@router.get("/{session_id}/labels", response_model=list[str])
async def get_labels_for_session(
    session_id: uuid.UUID, db: AsyncSession = Depends(get_db)
):
    session = await get_session(db, session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    return await get_session_labels(db, session_id)


@router.put("/{session_id}/labels", response_model=list[str])
async def set_labels_for_session(
    session_id: uuid.UUID,
    body: SessionLabelsIn,
    user_id: str = "default",
    db: AsyncSession = Depends(get_db),
):
    session = await get_session(db, session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    return await set_session_labels(db, session_id, user_id, body.labels)


@router.get("/{session_id}/messages", response_model=list[MessageOut])
async def get_messages(
    session_id: uuid.UUID, db: AsyncSession = Depends(get_db)
):
    session = await get_session(db, session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    messages = await get_session_messages(db, session_id)
    return [MessageOut(**m) for m in messages]


@router.post("/{session_id}/compact")
async def compact_session(
    session_id: uuid.UUID, db: AsyncSession = Depends(get_db),
):
    """Ask ark to compact this session's history down to a summary.
    Only valid for ark-backed sessions — non-ark providers have no
    compaction concept and return 400.

    Proxies to ark's POST /agents/{name}/sessions/{ark_sid}/compact.
    Ark fires compaction_started + _completed events over its /events
    stream; Relay picks them up in the ark client callback, persists
    the completed summary as a `compaction`-role message, and forwards
    each event to WS clients. So on success this endpoint just returns
    the immediate ark response; the visible session UI updates arrive
    via the WS event stream.
    """
    import httpx
    from app.db.redis import get_provider_state
    from app.services import agent_manager

    session = await get_session(db, session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    if agent is None or agent.llm_provider != "ark":
        raise HTTPException(
            status_code=400,
            detail="Compaction is only supported for ark-backed sessions.",
        )

    ark_sid = await get_provider_state(str(session_id), "ark")
    if not ark_sid:
        raise HTTPException(
            status_code=409,
            detail="Session has no ark session yet — send at least one message first.",
        )

    base_url, api_key = await agent_manager.resolve_llm_config(agent)
    if not base_url:
        raise HTTPException(
            status_code=502,
            detail="Ark server not configured for this agent.",
        )

    # ark agent name is the `llm_model` with any `ark:` prefix stripped.
    ark_agent = agent.llm_model
    if ark_agent.startswith("ark:"):
        ark_agent = ark_agent[len("ark:"):]

    url = f"{base_url.rstrip('/')}/agents/{ark_agent}/sessions/{ark_sid}/compact"
    headers = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(url, json={}, headers=headers)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Ark unreachable: {exc}")

    if resp.status_code >= 400:
        # Surface ark's error payload (which includes {ok, code, message})
        # verbatim so the client can render it usefully.
        try:
            detail = resp.json()
        except Exception:
            detail = resp.text
        raise HTTPException(status_code=resp.status_code, detail=detail)

    return resp.json()


@router.patch("/{session_id}/project", response_model=SessionOut)
async def set_session_project(
    session_id: uuid.UUID,
    body: SessionProjectIn,
    user_id: str = "default",
    db: AsyncSession = Depends(get_db),
):
    """Reassign, first-time-assign, or detach the ark project bound to
    this session.

    Proxies to ark's PATCH /agents/{name}/sessions/{ark_sid}/project. Ark
    validates that `project_id` (if given) belongs to the same server as
    the session and returns 404 otherwise; we surface that verbatim.

    On a real change ark fires `session_project_changed` on /events and
    persists a `ProjectAssignmentChanged` marker in its own history — the
    Relay ark client callback picks up the WS event, persists a
    `role="project_change"` marker locally, and broadcasts to clients.
    This handler just updates Relay's mirror columns
    (`project_id`/`project_server_id`) so the session list reflects the
    new binding immediately without waiting for the WS round-trip.
    """
    import httpx
    from app.db.redis import get_provider_state, invalidate_session_cache
    from app.services import agent_manager
    from app.services.llm.ark import _server_id_for

    session = await get_session(db, session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    if agent is None or agent.llm_provider != "ark":
        raise HTTPException(
            status_code=400,
            detail="Project assignment is only supported for ark-backed sessions.",
        )

    ark_sid = await get_provider_state(str(session_id), "ark")
    if not ark_sid:
        raise HTTPException(
            status_code=409,
            detail="Session has no ark session yet — send at least one message first.",
        )

    base_url, api_key = await agent_manager.resolve_llm_config(agent)
    if not base_url:
        raise HTTPException(
            status_code=502,
            detail="Ark server not configured for this agent.",
        )

    ark_agent = agent.llm_model
    if ark_agent.startswith("ark:"):
        ark_agent = ark_agent[len("ark:"):]

    url = f"{base_url.rstrip('/')}/agents/{ark_agent}/sessions/{ark_sid}/project"
    headers = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.patch(
                url, json={"project_id": body.project_id}, headers=headers,
            )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Ark unreachable: {exc}")

    if resp.status_code >= 400:
        try:
            detail = resp.json()
        except Exception:
            detail = resp.text
        raise HTTPException(status_code=resp.status_code, detail=detail)

    result = resp.json()
    # Mirror the new binding into Relay's row so the session list, filter
    # dropdowns, and chip renderer reflect it right away. Ark's response
    # includes `changed`; on no-ops we skip the write.
    if result.get("changed"):
        session.project_id = body.project_id
        # ark keeps sessions on a single server, so the server_id doesn't
        # change unless the session had no project before (or is now
        # unbound). Compute from the current agent's ark server.
        server_id = _server_id_for(base_url.rstrip("/"), api_key)
        session.project_server_id = server_id if body.project_id else None
        await db.commit()
        await invalidate_session_cache(str(session_id))

    labels = await get_session_labels(db, session_id)
    return SessionOut(
        session_id=str(session.session_id),
        agent_id=str(session.agent_id),
        agent_name=agent.name,
        status=session.status,
        created_at=session.created_at.isoformat(),
        last_active=session.last_active.isoformat(),
        name=session.name,
        summary=session.summary,
        labels=labels,
        project_id=session.project_id,
        project_server_id=session.project_server_id,
    )


# ── Labels endpoints ──────────────────────────────────────────────────


@labels_router.get("", response_model=list[LabelOut])
async def get_all_labels(
    user_id: str = "default", db: AsyncSession = Depends(get_db)
):
    labels = await list_user_labels(db, user_id)
    return [LabelOut(**l) for l in labels]
