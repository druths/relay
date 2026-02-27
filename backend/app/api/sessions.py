"""REST endpoints for session management."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.services.conversation_manager import (
    get_session,
    get_session_messages,
    list_sessions,
)

from app.api.auth import get_current_user

router = APIRouter(
    prefix="/v1/sessions",
    tags=["sessions"],
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


class MessageOut(BaseModel):
    message_id: str
    role: str
    text_content: str
    created_at: str


@router.get("", response_model=list[SessionOut])
async def get_sessions(
    user_id: str = "default", db: AsyncSession = Depends(get_db)
):
    sessions = await list_sessions(db, user_id)
    return [SessionOut(**s) for s in sessions]


@router.get("/{session_id}/messages", response_model=list[MessageOut])
async def get_messages(
    session_id: uuid.UUID, db: AsyncSession = Depends(get_db)
):
    session = await get_session(db, session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    messages = await get_session_messages(db, session_id)
    return [MessageOut(**m) for m in messages]
