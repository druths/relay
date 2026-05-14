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
from app.services.llm.ark import ArkProvider
from app.services.llm.openclaw import OpenClawProvider

logger = logging.getLogger(__name__)


async def get_agent_by_name(db: AsyncSession, name: str) -> Agent | None:
    """Case-insensitive lookup by agent display name (skipping soft-deletes).

    There can be multiple rows with the same name if an agent was deleted and
    recreated, so we explicitly filter out soft-deleted rows and pick the
    most-recently-created remaining match if more than one is live.
    """
    result = await db.execute(
        select(Agent)
            .where(Agent.name.ilike(name), Agent.deleted_at.is_(None))
            .order_by(Agent.agent_id.desc())
    )
    return result.scalars().first()


async def get_agent_by_id(db: AsyncSession, agent_id: uuid.UUID) -> Agent | None:
    # `populate_existing()` forces SQLAlchemy to refresh attributes on any
    # object that's already in the identity map. Without it, long-lived
    # sessions (e.g. the WebSocket session) keep returning a stale Agent
    # whose voice_id / tts_provider / etc. were captured at first load,
    # because `expire_on_commit=False` is set on the sessionmaker.
    result = await db.execute(
        select(Agent).where(Agent.agent_id == agent_id).execution_options(populate_existing=True)
    )
    return result.scalar_one_or_none()


async def list_agents(db: AsyncSession) -> list[Agent]:
    result = await db.execute(
        select(Agent).where(Agent.name != "Operator", Agent.deleted_at.is_(None))
            .order_by(Agent.sort_order, Agent.name)
    )
    return list(result.scalars().all())


async def list_all_agents(db: AsyncSession) -> list[Agent]:
    """List all agents including the Operator."""
    result = await db.execute(
        select(Agent).where(Agent.deleted_at.is_(None)).order_by(Agent.sort_order, Agent.name)
    )
    return list(result.scalars().all())


_VOICE_PREAMBLE = (
    "This is a voice conversation. Keep responses short and conversational — "
    "1-3 sentences unless the user asks for detail. Favor natural turn-taking "
    "over long monologues. Do not use markdown, lists, or formatting.\n\n"
)


def _build_system_prompt(agent: Agent, voice_instructions: str | None = None) -> str:
    persona = agent.persona_prompt or f"You are {agent.name}, a helpful assistant."
    preamble = (voice_instructions.strip() + "\n\n") if voice_instructions else _VOICE_PREAMBLE
    return preamble + persona


def _append_voice_note(messages: list[dict], voice_instructions: str) -> list[dict]:
    """Append a style note to the last user message in-memory (not persisted).

    Used for providers like OpenClaw that manage their own system prompt — we
    can't override their context, so we nudge the model via the user turn instead.
    """
    modified = list(messages)
    for i in range(len(modified) - 1, -1, -1):
        if modified[i]["role"] == "user":
            modified[i] = {
                **modified[i],
                "content": modified[i]["content"] + f"\n\n[Style note: {voice_instructions}]",
            }
            return modified
    return modified


async def generate_response(
    agent: Agent, text: str, context: list[dict],
    voice_instructions: str | None = None,
    session_id: uuid.UUID | None = None,
) -> str:
    """Generate a text response from an agent using its configured LLM provider."""
    provider = get_provider(agent.llm_provider, agent.llm_base_url, agent.llm_api_key)
    if provider is None:
        agent_health.set_error(agent.agent_id, f"{agent.llm_provider} API key not configured")
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

    if voice_instructions and isinstance(provider, OpenClawProvider):
        # OpenClaw manages its own system prompt — inject via user message instead
        messages = _append_voice_note(messages, voice_instructions)
        system_prompt = _build_system_prompt(agent)
    else:
        system_prompt = _build_system_prompt(agent, voice_instructions)

    # OpenClaw: use response chaining
    if isinstance(provider, OpenClawProvider) and session_id:
        from app.db.redis import get_openclaw_response_id, set_openclaw_response_id

        prev_id = await get_openclaw_response_id(str(session_id))
        try:
            result = await provider.generate_with_chain(
                system_prompt, messages, agent.llm_model,
                previous_response_id=prev_id,
            )
            if result.response_id:
                await set_openclaw_response_id(str(session_id), result.response_id)
            agent_health.set_healthy(agent.agent_id)
            return result.text
        except Exception as exc:
            logger.exception("LLM call failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            return f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."

    # Ark: each Relay session pins to a server-side ark session_id stored in
    # provider_state['ark']. Ark owns history; we only send the last turn.
    if isinstance(provider, ArkProvider) and session_id:
        from app.db.redis import get_provider_state, set_provider_state

        prev_sid = await get_provider_state(str(session_id), "ark")
        try:
            result = await provider.generate_with_chain(
                system_prompt, messages, agent.llm_model,
                previous_session_id=prev_sid,
            )
            if result.session_id:
                await set_provider_state(str(session_id), "ark", result.session_id)
            agent_health.set_healthy(agent.agent_id)
            return result.text
        except Exception as exc:
            logger.exception("LLM call failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            return f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."

    try:
        result = await provider.generate(system_prompt, messages, agent.llm_model)
        agent_health.set_healthy(agent.agent_id)
        return result
    except Exception as exc:
        logger.exception("LLM call failed for agent %s: %s", agent.name, exc)
        agent_health.set_error(agent.agent_id, str(exc)[:120])
        return f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."


async def generate_response_stream(
    agent: Agent, text: str, context: list[dict],
    voice_instructions: str | None = None,
    session_id: uuid.UUID | None = None,
) -> AsyncGenerator[str, None]:
    """Stream a text response from an agent using its configured LLM provider."""
    provider = get_provider(agent.llm_provider, agent.llm_base_url, agent.llm_api_key)
    if provider is None:
        agent_health.set_error(agent.agent_id, f"{agent.llm_provider} API key not configured")
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

    if voice_instructions and isinstance(provider, OpenClawProvider):
        # OpenClaw manages its own system prompt — inject via user message instead
        messages = _append_voice_note(messages, voice_instructions)
        system_prompt = _build_system_prompt(agent)
    else:
        system_prompt = _build_system_prompt(agent, voice_instructions)

    # OpenClaw: use response chaining instead of sending full history each time
    if isinstance(provider, OpenClawProvider) and session_id:
        from app.db.redis import get_openclaw_response_id, set_openclaw_response_id
        from app.services.llm.openclaw import OpenClawResult

        prev_id = await get_openclaw_response_id(str(session_id))
        try:
            async for chunk in provider.generate_stream_with_chain(
                system_prompt, messages, agent.llm_model,
                previous_response_id=prev_id,
            ):
                if isinstance(chunk, OpenClawResult):
                    if chunk.response_id:
                        await set_openclaw_response_id(str(session_id), chunk.response_id)
                else:
                    yield chunk
            agent_health.set_healthy(agent.agent_id)
        except Exception as exc:
            logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."
        return

    # Ark: same chain pattern but with a server-issued session_id.
    if isinstance(provider, ArkProvider) and session_id:
        from app.db.redis import get_provider_state, set_provider_state
        from app.services.llm.ark import ArkResult

        prev_sid = await get_provider_state(str(session_id), "ark")
        try:
            async for chunk in provider.generate_stream_with_chain(
                system_prompt, messages, agent.llm_model,
                previous_session_id=prev_sid,
            ):
                if isinstance(chunk, ArkResult):
                    if chunk.session_id:
                        await set_provider_state(str(session_id), "ark", chunk.session_id)
                else:
                    yield chunk
            agent_health.set_healthy(agent.agent_id)
        except Exception as exc:
            logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
            agent_health.set_error(agent.agent_id, str(exc)[:120])
            yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."
        return

    try:
        async for chunk in provider.generate_stream(system_prompt, messages, agent.llm_model):
            yield chunk
        agent_health.set_healthy(agent.agent_id)
    except Exception as exc:
        logger.exception("LLM stream failed for agent %s: %s", agent.name, exc)
        agent_health.set_error(agent.agent_id, str(exc)[:120])
        yield f"[{agent.name}] Sorry, I encountered an error generating a response. Please try again."
