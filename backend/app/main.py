"""Relay — API entry point."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

logging.basicConfig(level=logging.INFO)

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select, text

from app.api import agents, auth, platform, sessions, websocket
from app.db.database import async_session, engine
from app.models import Agent, Base, PlatformSetting
from app.services import agent_health


# ── Seed data ───────────────────────────────────────────────────────────

SEED_AGENTS = [
    {
        "name": "Operator",
        "persona_prompt": "You are the Relay Operator. Greet users briefly and help them pick an agent.",
        "tts_provider": "openai",
        "voice_id": "shimmer",
        "voice_settings": {"speed": 1.0},
        "llm_provider": "openai",
        "llm_model": "gpt-4o-mini",
    },
    {
        "name": "Vanto",
        "persona_prompt": "You are Vanto, a witty strategist. Confident and concise.",
        "tts_provider": "openai",
        "voice_id": "alloy",
        "voice_settings": {"speed": 1.0},
        "llm_provider": "openai",
        "llm_model": "gpt-4o-mini",
    },
    {
        "name": "Gemini",
        "persona_prompt": "You are Gemini, a sharp research assistant. Get to the point quickly and ask follow-ups.",
        "tts_provider": "openai",
        "voice_id": "nova",
        "voice_settings": {"speed": 1.0},
        "llm_provider": "gemini",
        "llm_model": "gemini-2.0-flash",
    },
    {
        "name": "Claude",
        "persona_prompt": "You are Claude, a thoughtful assistant. Reason carefully but keep it brief — expand only when asked.",
        "tts_provider": "openai",
        "voice_id": "echo",
        "voice_settings": {"speed": 1.0},
        "llm_provider": "anthropic",
        "llm_model": "claude-sonnet-4-5-20250929",
    },
]


async def _seed_agents() -> None:
    """Insert seed agents if the table is empty."""
    async with async_session() as db:
        result = await db.execute(select(Agent).limit(1))
        if result.scalar_one_or_none() is not None:
            return  # Already seeded

        for data in SEED_AGENTS:
            db.add(Agent(**data))
        await db.commit()


async def _seed_platform_settings() -> None:
    """Insert default platform settings if the table is empty."""
    async with async_session() as db:
        result = await db.execute(select(PlatformSetting).limit(1))
        if result.scalar_one_or_none() is not None:
            return
        db.add(PlatformSetting(key="stt_provider", value="openai"))
        db.add(PlatformSetting(key="stt_api_key", value=""))
        await db.commit()


# ── App lifecycle ───────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables (new tables auto-created; new columns need ALTER)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.execute(text(
            "ALTER TABLE agents ADD COLUMN IF NOT EXISTS llm_api_key VARCHAR(500)"
        ))
        await conn.execute(text(
            "ALTER TABLE agents ADD COLUMN IF NOT EXISTS tts_api_key VARCHAR(500)"
        ))
        await conn.execute(text(
            "ALTER TABLE agents ADD COLUMN IF NOT EXISTS sort_order INTEGER NOT NULL DEFAULT 0"
        ))
        await conn.execute(text(
            "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS has_unread BOOLEAN NOT NULL DEFAULT FALSE"
        ))
        await conn.execute(text(
            "ALTER TABLE agents ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ"
        ))
        await conn.execute(text(
            "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ"
        ))
        await conn.execute(text(
            "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS openclaw_response_id VARCHAR(200)"
        ))
    # Seed data
    await _seed_agents()
    await _seed_platform_settings()
    # Expose session factory on app state for the WebSocket handler
    app.state.db_session = async_session
    yield
    await engine.dispose()


# ── App setup ───────────────────────────────────────────────────────────

app = FastAPI(title="Relay", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(agents.router)
app.include_router(platform.router)
app.include_router(sessions.router)
app.include_router(sessions.labels_router)
app.include_router(websocket.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
