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
    db: AsyncSession = Depends(get_db),
):
    sessions = await list_sessions(db, user_id, label_filter=label)
    return [SessionOut(**s) for s in sessions]


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
