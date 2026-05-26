"""Relay — API entry point."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

logging.basicConfig(level=logging.INFO)

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select, text

from app.api import agents, auth, files, platform, projects, sessions, websocket
from app.db.database import async_session, engine
from app.models import Agent, Base, File, PlatformSetting
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
        # Per-provider continuation state. Backfill the legacy openclaw column
        # into the new JSON dict so live sessions don't lose chain context.
        await conn.execute(text(
            "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS provider_state JSONB NOT NULL DEFAULT '{}'::jsonb"
        ))
        await conn.execute(text(
            "UPDATE sessions SET provider_state = jsonb_build_object('openclaw', openclaw_response_id) "
            "WHERE openclaw_response_id IS NOT NULL AND NOT (provider_state ? 'openclaw')"
        ))
        # Distinguishes user-uploaded attachments from agent-shared files in
        # session history replay.
        await conn.execute(text(
            "ALTER TABLE files ADD COLUMN IF NOT EXISTS role VARCHAR(20) NOT NULL DEFAULT 'user'"
        ))
        # ark project binding (nullable). Plain TEXT — projects live on ark,
        # not in Relay's DB. `project_server_id` disambiguates the project_id
        # across multiple ark servers (stores the normalized ark base URL).
        await conn.execute(text(
            "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS project_id VARCHAR(64)"
        ))
        await conn.execute(text(
            "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS project_server_id VARCHAR(256)"
        ))
        # Widen pre-existing column if it was created at 64 chars (URLs can
        # exceed that for some deployments).
        await conn.execute(text(
            "ALTER TABLE sessions ALTER COLUMN project_server_id TYPE VARCHAR(256)"
        ))
    # Seed data
    await _seed_agents()
    await _seed_platform_settings()
    # One-time: migrate ark `server_id` from the legacy SHA256 hash to the
    # normalized base URL. Walks configured ark agents, computes the old
    # hash for each, and rewrites `platform_settings.key` +
    # `sessions.project_server_id` rows in place. Safe to re-run.
    await _migrate_legacy_ark_server_ids()
    # Expose session factory on app state for the WebSocket handler
    app.state.db_session = async_session
    # Warm ark connections for any agents users have configured. This runs
    # catch-up so anything that happened on ark while we were down (cron
    # firings, injected messages, file shares) is picked up before users
    # reconnect — populating has_unread and message history as needed.
    import asyncio as _asyncio
    _asyncio.create_task(_warm_ark_connections())
    yield
    # Tear down any live ark WebSocket connections before closing the engine.
    from app.services.llm.ark import close_all_connections
    await close_all_connections()
    await engine.dispose()


async def _migrate_legacy_ark_server_ids() -> None:
    """One-shot migration: rewrite legacy SHA256 `server_id` values to the
    new URL-based scheme everywhere they appear (catch-up cursor keys +
    `sessions.project_server_id`). Idempotent — second runs find no
    matching legacy keys and exit quickly."""
    import logging
    mig_logger = logging.getLogger("ark.migration")
    try:
        from app.services.agent_manager import resolve_llm_config
        from app.services.llm.ark import _legacy_server_id_for, _server_id_for

        async with async_session() as db:
            res = await db.execute(
                select(Agent).where(
                    Agent.deleted_at.is_(None),
                    Agent.llm_provider == "ark",
                )
            )
            agents = list(res.scalars().all())

            # Build {legacy_hash → url} for every distinct configured ark.
            hash_to_url: dict[str, str] = {}
            for agent in agents:
                base_url, api_key = await resolve_llm_config(agent)
                if not base_url:
                    continue
                base = base_url.rstrip("/")
                old = _legacy_server_id_for(base, api_key)
                new = _server_id_for(base)
                if old != new:
                    hash_to_url[old] = new

            if not hash_to_url:
                return

            for old, new in hash_to_url.items():
                # Cursor row(s) — copy old → new key, drop old.
                await db.execute(
                    text(
                        "INSERT INTO platform_settings (key, value) "
                        "SELECT :new_key, value FROM platform_settings "
                        "WHERE key = :old_key "
                        "ON CONFLICT (key) DO NOTHING"
                    ),
                    {"old_key": f"ark_cursor:{old}", "new_key": f"ark_cursor:{new}"},
                )
                await db.execute(
                    text("DELETE FROM platform_settings WHERE key = :old_key"),
                    {"old_key": f"ark_cursor:{old}"},
                )
                # Session bindings.
                await db.execute(
                    text(
                        "UPDATE sessions SET project_server_id = :new_sid "
                        "WHERE project_server_id = :old_sid"
                    ),
                    {"old_sid": old, "new_sid": new},
                )
            await db.commit()
        mig_logger.info("Migrated %d legacy ark server_id(s) to URL form", len(hash_to_url))
    except Exception:
        mig_logger.exception("Legacy ark server_id migration failed")


async def _warm_ark_connections() -> None:
    """At boot, open the per-server ark connection for every distinct ark
    agent on the system (deduped by base_url+api_key). Lets catch-up run so
    Relay reconciles any messages that arrived while the backend was down."""
    import logging
    warm_logger = logging.getLogger("ark.warmup")
    try:
        from app.services.agent_manager import ensure_ark_connection
        async with async_session() as db:
            res = await db.execute(
                select(Agent).where(
                    Agent.deleted_at.is_(None),
                    Agent.llm_provider == "ark",
                )
            )
            agents = list(res.scalars().all())
        seen: set[str] = set()
        for agent in agents:
            key = f"{agent.llm_base_url or ''}|{agent.llm_api_key or ''}"
            if key in seen:
                continue
            seen.add(key)
            try:
                await ensure_ark_connection(agent)
            except Exception:
                warm_logger.exception("warm-up failed for agent %s", agent.name)
    except Exception:
        warm_logger.exception("ark warm-up sweep failed")


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
app.include_router(files.router)
app.include_router(projects.projects_router)
app.include_router(projects.workspaces_router)
app.include_router(websocket.router)


@app.get("/health")
async def health():
    return {"status": "ok"}
