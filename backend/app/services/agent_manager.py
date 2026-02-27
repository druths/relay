"""Agent Manager — resolves agent identity and generates responses via LLM providers."""

from __future__ import annotations

import logging
import uuid
from collections.abc import AsyncGenerator

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.agent import Agent
from app.services import agent_health
from app.services.llm import get_provider

logger = logging.getLogger(__name__)


async def get_agent_by_name(db: AsyncSession, name: str) -> Agent | None:
    """Case-insensitive lookup by agent display name."""
    result = await db.execute(
        select(Agent).where(Agent.name.ilike(name))
    )
    return result.scalar_one_or_none()


async def get_agent_by_id(db: AsyncSession, agent_id: uuid.UUID) -> Agent | None:
    result = await db.execute(
        select(Agent).where(Agent.agent_id == agent_id)
    )
    return result.scalar_one_or_none()


async def list_agents(db: AsyncSession) -> list[Agent]:
    result = await db.execute(
        select(Agent).where(Agent.name != "Operator").order_by(Agent.name)
    )
    return list(result.scalars().all())


async def list_all_agents(db: AsyncSession) -> list[Agent]:
    """List all agents including the Operator."""
    result = await db.execute(select(Agent).order_by(Agent.name))
    return list(result.scalars().all())


_VOICE_PREAMBLE = (
    "This is a voice conversation. Keep responses short and conversational — "
    "1-3 sentences unless the user asks for detail. Favor natural turn-taking "
    "over long monologues. Do not use markdown, lists, or formatting.\n\n"
)


def _build_system_prompt(agent: Agent) -> str:
    persona = agent.persona_prompt or f"You are {agent.name}, a helpful assistant."
    return _VOICE_PREAMBLE + persona


async def generate_response(agent: Agent, text: str, context: list[dict]) -> str:
    """Generate a text response from an agent using its configured LLM provider."""
    health = agent_health.get_status(agent.agent_id)
    if health.status == "error":
        return f"[{agent.name}] Agent is currently unavailable: {health.message}"

    provider = get_provider(agent.llm_provider, agent.llm_base_url, agent.llm_api_key)
    if provider is None:
        return (
            f"[{agent.name}] LLM provider '{agent.llm_provider}' is not configured. "
            f"Please check the API key for this provider."
        )

    # Convert internal message format to LLM format
    messages = []
    for msg in context:
        role = "assistant" if msg["role"] == "agent" else msg["role"]
        if role in ("user", "assistant"):
            messages.append({"role": role, "content": msg["text_content"]})

    system_prompt = _build_system_prompt(agent)

    try:
        return await provider.generate(system_prompt, messages, agent.llm_model)
    except Exception as exc:
        logger.exception("LLM call failed for agent %s: %s", agent.name, exc)
        return f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."


async def generate_response_stream(
    agent: Agent, text: str, context: list[dict]
) -> AsyncGenerator[str, None]:
    """Stream a text response from an agent using its configured LLM provider."""
    health = agent_health.get_status(agent.agent_id)
    if health.status == "error":
        yield f"[{agent.name}] Agent is currently unavailable: {health.message}"
        return

    provider = get_provider(agent.llm_provider, agent.llm_base_url, agent.llm_api_key)
    if provider is None:
        yield (
            f"[{agent.name}] LLM provider '{agent.llm_provider}' is not configured. "
            f"Please check the API key for this provider."
        )
        return

    messages = []
    for msg in context:
        role = "assistant" if msg["role"] == "agent" else msg["role"]
        if role in ("user", "assistant"):
            messages.append({"role": role, "content": msg["text_content"]})

    system_prompt = _build_system_prompt(agent)

    try:
        async for chunk in provider.generate_stream(system_prompt, messages, agent.llm_model):
            yield chunk
    except Exception as exc:
        logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
        yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."
