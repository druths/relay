"""Relay — API entry point."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

logging.basicConfig(level=logging.INFO)

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select

from app.api import agents, sessions, websocket
from app.db.database import async_session, engine
from app.models import Agent, Base
from app.services import agent_health


# ── Seed data ───────────────────────────────────────────────────────────

SEED_AGENTS = [
    {
        "name": "Operator",
        "persona_prompt": "You are the Relay Operator, a helpful concierge that routes users to the right agent.",
        "tts_provider": "openai",
        "voice_id": "shimmer",
        "voice_settings": {"speed": 1.0},
        "llm_provider": "openai",
        "llm_model": "gpt-4o-mini",
    },
    {
        "name": "Vanto",
        "persona_prompt": "You are Vanto, a helpful and witty strategist. You speak concisely and with confidence.",
        "tts_provider": "openai",
        "voice_id": "alloy",
        "voice_settings": {"speed": 1.0},
        "llm_provider": "openai",
        "llm_model": "gpt-4o-mini",
    },
    {
        "name": "Gemini",
        "persona_prompt": "You are Gemini, a knowledgeable research assistant. You provide thorough, well-sourced answers.",
        "tts_provider": "openai",
        "voice_id": "nova",
        "voice_settings": {"speed": 1.0},
        "llm_provider": "gemini",
        "llm_model": "gemini-2.0-flash",
    },
    {
        "name": "Claude",
        "persona_prompt": "You are Claude, a thoughtful and careful assistant. You reason step by step and are transparent about uncertainty.",
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


# ── App lifecycle ───────────────────────────────────────────────────────

async def _periodic_health_check() -> None:
    """Re-check agent health every 5 minutes."""
    while True:
        await asyncio.sleep(300)
        try:
            async with async_session() as db:
                result = await db.execute(select(Agent))
                all_agents = list(result.scalars().all())
            await agent_health.check_all(all_agents)
        except asyncio.CancelledError:
            return
        except Exception as exc:
            logging.getLogger(__name__).warning("Periodic health check failed: %s", exc)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    # Seed data
    await _seed_agents()
    # Initial health check
    async with async_session() as db:
        result = await db.execute(select(Agent))
        all_agents = list(result.scalars().all())
    await agent_health.check_all(all_agents)
    # Start periodic health check
    health_task = asyncio.create_task(_periodic_health_check())
    # Expose session factory on app state for the WebSocket handler
    app.state.db_session = async_session
    yield
    health_task.cancel()
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

app.include_router(agents.router)
app.include_router(sessions.router)
app.include_router(websocket.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
