"""REST endpoints for agent management."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.utils import mask_api_key
from app.db.database import get_db
from app.models.agent import Agent
from app.models.session import Session
from app.services.agent_manager import get_agent_by_id, list_agents, list_all_agents
from app.models.platform_setting import PlatformSetting
from app.services.tts import fetch_voices_async

from app.api.auth import get_current_user

router = APIRouter(
    prefix="/v1/agents",
    tags=["agents"],
    dependencies=[Depends(get_current_user)],
)


class AgentOut(BaseModel):
    agent_id: str
    name: str
    persona_prompt: str
    tts_provider: str
    voice_id: str
    voice_settings: dict
    llm_provider: str
    llm_model: str
    llm_base_url: str | None = None
    llm_api_key: str | None = None
    tts_api_key: str | None = None
    is_operator: bool = False
    status: str = "unknown"
    status_message: str = ""
    sort_order: int = 0

    model_config = {"from_attributes": True}


class AgentCreate(BaseModel):
    name: str
    persona_prompt: str = ""
    tts_provider: str = "none"
    voice_id: str = ""
    voice_settings: dict = {}
    llm_provider: str = "openai"
    llm_model: str = "gpt-4o-mini"
    llm_base_url: str | None = None
    llm_api_key: str | None = None
    tts_api_key: str | None = None


class AgentConfigUpdate(BaseModel):
    name: str | None = None
    voice_settings: dict | None = None
    voice_id: str | None = None
    tts_provider: str | None = None
    persona_prompt: str | None = None
    llm_provider: str | None = None
    llm_model: str | None = None
    llm_base_url: str | None = None
    llm_api_key: str | None = None
    tts_api_key: str | None = None


def _agent_out(a) -> AgentOut:
    from app.services.agent_health import get_status
    health = get_status(a.agent_id)
    return AgentOut(
        agent_id=str(a.agent_id),
        name=a.name,
        persona_prompt=a.persona_prompt,
        tts_provider=a.tts_provider,
        voice_id=a.voice_id,
        voice_settings=a.voice_settings,
        llm_provider=a.llm_provider,
        llm_model=a.llm_model,
        llm_base_url=a.llm_base_url,
        llm_api_key=mask_api_key(a.llm_api_key),
        tts_api_key=mask_api_key(a.tts_api_key),
        is_operator=(a.name == "Operator"),
        sort_order=a.sort_order,
        status=health.status,
        status_message=health.message,
    )


@router.get("", response_model=list[AgentOut])
async def get_agents(
    include_operator: bool = False,
    db: AsyncSession = Depends(get_db),
):
    agents = await list_all_agents(db) if include_operator else await list_agents(db)
    return [_agent_out(a) for a in agents]


@router.post("", response_model=AgentOut, status_code=201)
async def create_agent(
    body: AgentCreate,
    db: AsyncSession = Depends(get_db),
):
    agent = Agent(
        name=body.name,
        persona_prompt=body.persona_prompt,
        tts_provider=body.tts_provider,
        voice_id=body.voice_id,
        voice_settings=body.voice_settings or {},
        llm_provider=body.llm_provider,
        llm_model=body.llm_model,
        llm_base_url=body.llm_base_url,
        llm_api_key=body.llm_api_key,
        tts_api_key=body.tts_api_key,
    )
    db.add(agent)
    await db.commit()
    await db.refresh(agent)

    from app.services.agent_health import check_agent
    await check_agent(agent)

    return _agent_out(agent)


@router.delete("/{agent_id}", status_code=204)
async def delete_agent(
    agent_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    agent = await get_agent_by_id(db, agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail="Agent not found")

    if agent.name == "Operator":
        raise HTTPException(status_code=400, detail="Cannot delete the Operator agent")

    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)

    # Soft-delete all sessions for this agent
    result = await db.execute(
        select(Session).where(
            Session.agent_id == agent_id,
            Session.deleted_at.is_(None),
        )
    )
    for session in result.scalars().all():
        session.deleted_at = now

    # Soft-delete the agent
    agent.deleted_at = now
    await db.commit()


class AgentReorder(BaseModel):
    agent_ids: list[str]


@router.put("/reorder", response_model=list[AgentOut])
async def reorder_agents(
    body: AgentReorder,
    db: AsyncSession = Depends(get_db),
):
    """Set the sort order of agents. The list should contain agent IDs in the desired order.
    Operator is always pinned to sort_order 0 and should not be included."""
    for i, agent_id_str in enumerate(body.agent_ids):
        agent_id = uuid.UUID(agent_id_str)
        agent = await get_agent_by_id(db, agent_id)
        if agent and agent.name != "Operator":
            agent.sort_order = i + 1  # Operator stays at 0
    await db.commit()
    agents = await list_all_agents(db)
    return [_agent_out(a) for a in agents]


@router.get("/tts/models/{provider}")
async def get_tts_models(
    provider: str,
    api_key: str | None = None,
    base_url: str | None = None,
    db: AsyncSession = Depends(get_db),
):
    """Fetch available TTS models for a provider."""
    if provider != "openai":
        return []

    effective_key = api_key
    if not effective_key and not base_url:
        result = await db.execute(
            select(PlatformSetting).where(
                PlatformSetting.key == f"tts_{provider}_api_key"
            )
        )
        row = result.scalar_one_or_none()
        effective_key = row.value if row and row.value else None
    if not effective_key and not base_url:
        from app.config import settings
        effective_key = settings.openai_api_key or None

    if not effective_key and not base_url:
        # No key and no custom endpoint — return known OpenAI models
        return [
            {"id": "tts-1", "name": "TTS-1"},
            {"id": "tts-1-hd", "name": "TTS-1 HD"},
            {"id": "gpt-4o-mini-tts", "name": "GPT-4o Mini TTS"},
        ]

    if base_url:
        # Custom endpoint — query it, but simplify to "default" if only aliases
        try:
            from openai import AsyncOpenAI
            effective_base = base_url.rstrip("/") + "/v1" if not base_url.rstrip("/").endswith("/v1") else base_url
            client = AsyncOpenAI(api_key="not-needed", base_url=effective_base)
            models = await client.models.list()
            model_ids = [m.id for m in models.data]

            # If server only reports OpenAI-compat aliases (tts-1, tts-1-hd) plus its own name,
            # just return "default" since they're all the same engine
            non_alias = [mid for mid in model_ids if mid not in ("tts-1", "tts-1-hd")]
            if len(non_alias) <= 1:
                return [{"id": "default", "name": "Default"}]

            # Multiple real models — return them (exclude tts-1/tts-1-hd aliases)
            return [{"id": mid, "name": mid} for mid in sorted(non_alias)]
        except Exception:
            return [{"id": "default", "name": "Default"}]

    # OpenAI with key — query real models
    try:
        from openai import AsyncOpenAI
        client = AsyncOpenAI(api_key=effective_key)
        models = await client.models.list()
        tts_models = [
            {"id": m.id, "name": m.id}
            for m in sorted(models.data, key=lambda x: x.id)
            if "tts" in m.id.lower()
        ]
        return tts_models if tts_models else [
            {"id": "tts-1", "name": "TTS-1"},
            {"id": "tts-1-hd", "name": "TTS-1 HD"},
        ]
    except Exception:
        return [
            {"id": "tts-1", "name": "TTS-1"},
            {"id": "tts-1-hd", "name": "TTS-1 HD"},
            {"id": "gpt-4o-mini-tts", "name": "GPT-4o Mini TTS"},
        ]


@router.get("/tts/voices/{provider}")
async def get_tts_voices(
    provider: str,
    api_key: str | None = None,
    model_id: str | None = None,
    base_url: str | None = None,
    db: AsyncSession = Depends(get_db),
):
    # If a custom base_url is provided, fetch voices directly from that server
    if base_url and provider == "openai":
        try:
            import httpx
            url = base_url.rstrip("/") + "/v1/audio/voices"
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(url)
                resp.raise_for_status()
                data = resp.json()
                # Kokoro returns {"voices": ["name1", "name2", ...]}
                voice_list = data.get("voices", data) if isinstance(data, dict) else data
                if isinstance(voice_list, list) and voice_list and isinstance(voice_list[0], str):
                    return [{"id": v, "name": v, "description": ""} for v in voice_list]
                return voice_list
        except Exception:
            pass
        # Fallback to static list
        from app.services.tts.openai import OpenAITTSProvider
        return OpenAITTSProvider.available_voices()

    effective_key = api_key
    if not effective_key:
        result = await db.execute(
            select(PlatformSetting).where(
                PlatformSetting.key == f"tts_{provider}_api_key"
            )
        )
        row = result.scalar_one_or_none()
        effective_key = row.value if row and row.value else None
    if not effective_key and provider == "openai":
        from app.config import settings
        effective_key = settings.openai_api_key or None
    return await fetch_voices_async(provider, effective_key or "", model_id=model_id)


@router.post("/{agent_id}/health-check", response_model=AgentOut)
async def check_agent_health(
    agent_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    """Manually trigger a health check for a specific agent."""
    agent = await get_agent_by_id(db, agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail="Agent not found")

    from app.services.agent_health import check_agent
    await check_agent(agent)
    return _agent_out(agent)


@router.get("/stt/status")
async def get_stt_status(db: AsyncSession = Depends(get_db)):
    from app.services.stt import get_stt_provider_from_db
    provider = await get_stt_provider_from_db(db)
    return {"available": provider is not None}


@router.patch("/{agent_id}/config", response_model=AgentOut)
async def update_agent_config(
    agent_id: uuid.UUID,
    body: AgentConfigUpdate,
    db: AsyncSession = Depends(get_db),
):
    agent = await get_agent_by_id(db, agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail="Agent not found")

    if body.name is not None:
        if agent.name != "Operator":
            agent.name = body.name
    if body.voice_settings is not None:
        agent.voice_settings = body.voice_settings
    if body.voice_id is not None:
        agent.voice_id = body.voice_id
    if body.tts_provider is not None:
        agent.tts_provider = body.tts_provider
    if body.persona_prompt is not None:
        agent.persona_prompt = body.persona_prompt
    if body.llm_provider is not None:
        agent.llm_provider = body.llm_provider
    if body.llm_model is not None:
        agent.llm_model = body.llm_model
    if body.llm_base_url is not None:
        agent.llm_base_url = body.llm_base_url or None

    # API keys: empty string clears (falls back to env var), None means untouched
    if body.llm_api_key is not None:
        agent.llm_api_key = body.llm_api_key or None
    if body.tts_api_key is not None:
        agent.tts_api_key = body.tts_api_key or None

    await db.commit()
    await db.refresh(agent)

    # Re-check health if LLM config changed (fire-and-forget so save returns immediately)
    if any(v is not None for v in (body.llm_provider, body.llm_model, body.llm_base_url, body.llm_api_key)):
        from app.services.agent_health import check_agent
        import asyncio
        asyncio.ensure_future(check_agent(agent))

    return _agent_out(agent)
