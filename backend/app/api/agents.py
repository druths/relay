"""REST endpoints for agent management."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.services.agent_manager import get_agent_by_id, list_agents, list_all_agents
from app.services.tts import get_available_voices

router = APIRouter(prefix="/v1/agents", tags=["agents"])


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
    status: str = "unknown"
    status_message: str = ""

    model_config = {"from_attributes": True}


class AgentConfigUpdate(BaseModel):
    voice_settings: dict | None = None
    voice_id: str | None = None
    tts_provider: str | None = None
    persona_prompt: str | None = None
    llm_provider: str | None = None
    llm_model: str | None = None
    llm_base_url: str | None = None


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


@router.get("/tts/voices/{provider}")
async def get_tts_voices(provider: str):
    return get_available_voices(provider)


@router.get("/stt/status")
async def get_stt_status():
    from app.services.stt import is_stt_available
    return {"available": is_stt_available()}


@router.patch("/{agent_id}/config", response_model=AgentOut)
async def update_agent_config(
    agent_id: uuid.UUID,
    body: AgentConfigUpdate,
    db: AsyncSession = Depends(get_db),
):
    agent = await get_agent_by_id(db, agent_id)
    if not agent:
        raise HTTPException(status_code=404, detail="Agent not found")

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

    await db.commit()
    await db.refresh(agent)

    # Re-check health if LLM config changed
    if body.llm_provider is not None or body.llm_model is not None or body.llm_base_url is not None:
        from app.services.agent_health import check_agent
        await check_agent(agent)

    return _agent_out(agent)
