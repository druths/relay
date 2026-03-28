"""Agent health check service — proactively validates LLM connectivity."""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

from app.models.agent import Agent
from app.services.llm import get_provider

logger = logging.getLogger(__name__)


@dataclass
class AgentHealth:
    status: str = "unknown"  # "healthy", "error", "unknown"
    message: str = ""
    checked_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


# In-memory health cache keyed by agent_id
_health: dict[uuid.UUID, AgentHealth] = {}


def get_status(agent_id: uuid.UUID) -> AgentHealth:
    return _health.get(agent_id, AgentHealth())


def get_all_statuses() -> dict[uuid.UUID, AgentHealth]:
    return dict(_health)


async def check_agent(agent: Agent) -> AgentHealth:
    """Test an agent's LLM provider with a minimal call."""
    provider = get_provider(agent.llm_provider, agent.llm_base_url, agent.llm_api_key)
    if provider is None:
        health = AgentHealth(
            status="error",
            message=f"{agent.llm_provider} API key not configured",
            checked_at=datetime.now(timezone.utc),
        )
        _health[agent.agent_id] = health
        logger.info("Health check %s: %s — %s", agent.name, health.status, health.message)
        return health

    try:
        await provider.generate(
            "Reply with exactly: OK",
            [{"role": "user", "content": "health check"}],
            agent.llm_model,
        )
        health = AgentHealth(
            status="healthy",
            message="",
            checked_at=datetime.now(timezone.utc),
        )
    except Exception as exc:
        logger.warning("Health check %s exception: %r", agent.name, exc, exc_info=True)
        error_msg = str(exc)
        # Extract useful part of common API errors
        if "401" in error_msg or "Unauthorized" in error_msg:
            error_msg = "Invalid API key"
        elif "403" in error_msg or "Forbidden" in error_msg:
            error_msg = "API key lacks permission"
        elif "429" in error_msg:
            error_msg = "Rate limited"
        elif len(error_msg) > 120:
            error_msg = error_msg[:120] + "..."

        health = AgentHealth(
            status="error",
            message=error_msg,
            checked_at=datetime.now(timezone.utc),
        )

    _health[agent.agent_id] = health
    logger.info("Health check %s: %s%s", agent.name, health.status,
                f" — {health.message}" if health.message else "")
    return health


async def check_all(agents: list[Agent]) -> None:
    """Check all agents concurrently."""
    await asyncio.gather(*(check_agent(a) for a in agents), return_exceptions=True)
