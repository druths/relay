import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, ForeignKey, String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class Session(Base):
    __tablename__ = "sessions"

    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[str] = mapped_column(String(100), nullable=False, default="default")
    agent_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("agents.agent_id"), nullable=False
    )
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="active"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
    last_active: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )
    name: Mapped[str | None] = mapped_column(String(200), nullable=True, default=None)
    summary: Mapped[str | None] = mapped_column(Text, nullable=True, default=None)
    has_unread: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, default=None)
    # Optional binding to an ark project. Mirrors ark's per-session
    # `project_id` so Relay can render the project chip, group in the sidebar,
    # and pass the binding through on lazy ark session creation. Immutable
    # for the life of the session (matches ark's semantics). Plain TEXT
    # column (not FK) because the canonical projects table lives in ark.
    project_id: Mapped[str | None] = mapped_column(String(64), nullable=True, default=None)
    # `server_id` of the ark server hosting `project_id` — the normalized
    # base URL (e.g. `http://ark-ds.t.internal:7777`). Lets passthrough
    # endpoints route to the right ark without re-querying every server
    # when looking up a project by id.
    project_server_id: Mapped[str | None] = mapped_column(String(256), nullable=True, default=None)
    # Legacy single-provider state column — kept for backfill compatibility.
    # New code should use `provider_state[<provider_name>]`.
    openclaw_response_id: Mapped[str | None] = mapped_column(String(200), nullable=True, default=None)
    # Per-provider continuation state, keyed by provider name (e.g. "openclaw"
    # carries a response_id; "ark" carries a server-issued session_id).
    provider_state: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict, server_default="{}")
