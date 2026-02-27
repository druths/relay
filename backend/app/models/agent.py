import uuid

from sqlalchemy import String, Text
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base


class Agent(Base):
    __tablename__ = "agents"

    agent_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    persona_prompt: Mapped[str] = mapped_column(Text, nullable=False, default="")
    tts_provider: Mapped[str] = mapped_column(String(50), nullable=False, default="none")
    voice_id: Mapped[str] = mapped_column(String(100), nullable=False, default="")
    voice_settings: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    llm_provider: Mapped[str] = mapped_column(String(50), nullable=False, default="openai")
    llm_model: Mapped[str] = mapped_column(String(100), nullable=False, default="gpt-4o-mini")
    llm_base_url: Mapped[str | None] = mapped_column(String(500), nullable=True, default=None)
    llm_api_key: Mapped[str | None] = mapped_column(String(500), nullable=True, default=None)
    tts_api_key: Mapped[str | None] = mapped_column(String(500), nullable=True, default=None)
