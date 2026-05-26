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


class LabelOut(BaseModel):
    label_id: str
    name: str


@router.get("", response_model=list[SessionOut])
async def get_sessions(
    user_id: str = "default",
    label: str | None = Query(None, description="Filter sessions by label name"),
    search: str | None = Query(None, description="Search by session name, summary, or agent name"),
    db: AsyncSession = Depends(get_db),
):
    sessions = await list_sessions(db, user_id, label_filter=label, search=search)
    return [SessionOut(**s) for s in sessions]


class SessionCreateIn(BaseModel):
    agent_id: str
    project_id: str | None = None
    # Required when `project_id` is set and multiple ark servers are in play —
    # mirrors the projects-passthrough scoping. Stored on the row so future
    # operations on the session can locate the right ark.
    project_server_id: str | None = None
    labels: list[str] | None = None


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


# ── Labels endpoints ──────────────────────────────────────────────────


@labels_router.get("", response_model=list[LabelOut])
async def get_all_labels(
    user_id: str = "default", db: AsyncSession = Depends(get_db)
):
    labels = await list_user_labels(db, user_id)
    return [LabelOut(**l) for l in labels]
