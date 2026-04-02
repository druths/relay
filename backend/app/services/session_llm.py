"""
LLM utilities for session naming and summarization.

Uses the Operator's LLM config (provider, model, base_url, api_key) from the DB.
"""

from __future__ import annotations

import logging

from app.services.llm.anthropic import _get_client as _get_anthropic_client
from app.services.llm.openai import _get_client as _get_openai_client

logger = logging.getLogger(__name__)


async def _simple_llm_call(
    provider: str,
    model: str,
    base_url: str | None,
    api_key: str | None,
    system_prompt: str,
    user_content: str,
    max_tokens: int = 100,
) -> str | None:
    """Make a simple single-turn LLM call, dispatching by provider."""
    if provider == "anthropic":
        client = _get_anthropic_client(api_key)
        if client is None:
            return None
        response = await client.messages.create(
            model=model,
            system=system_prompt,
            messages=[{"role": "user", "content": user_content}],
            max_tokens=max_tokens,
        )
        return response.content[0].text.strip() if response.content else None
    else:
        client = _get_openai_client(base_url, api_key)
        if client is None:
            return None
        response = await client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            max_tokens=max_tokens,
            temperature=0.3,
        )
        return (response.choices[0].message.content or "").strip() or None


async def generate_session_name(
    first_user_message: str,
    first_agent_response: str,
    agent_name: str,
    *,
    provider: str = "openai",
    model: str = "gpt-4o-mini",
    base_url: str | None = None,
    api_key: str | None = None,
) -> str:
    """Generate a short 3-5 word title for a session from the first exchange."""
    try:
        result = await _simple_llm_call(
            provider, model, base_url, api_key,
            system_prompt=(
                "Generate a short title (3-5 words) that captures the topic of this conversation. "
                "Return ONLY the title, no quotes, no punctuation at the end."
            ),
            user_content=(
                f"User said to {agent_name}: \"{first_user_message}\"\n"
                f"{agent_name} replied: \"{first_agent_response[:200]}\""
            ),
            max_tokens=20,
        )
        if result:
            logger.info("Session name generated: %s", result)
            return result[:200]
    except Exception as exc:
        logger.warning("Session naming LLM failed, using fallback: %s", exc)

    return _fallback_name(first_user_message)


def _fallback_name(first_user_message: str) -> str:
    truncated = first_user_message[:40].strip()
    if len(first_user_message) > 40:
        truncated += "..."
    return truncated


async def generate_session_summary(
    messages: list[dict],
    agent_name: str,
    *,
    provider: str = "openai",
    model: str = "gpt-4o-mini",
    base_url: str | None = None,
    api_key: str | None = None,
) -> str:
    """Generate a 1-2 sentence summary of the session conversation."""
    recent = messages[-15:]
    transcript = "\n".join(
        f"{m['role']}: {m['text_content'][:150]}" for m in recent
    )

    try:
        result = await _simple_llm_call(
            provider, model, base_url, api_key,
            system_prompt=(
                "Summarize this conversation in 1-2 sentences. "
                "Focus on what was discussed and any conclusions reached. "
                "Return ONLY the summary."
            ),
            user_content=transcript,
            max_tokens=100,
        )
        if result:
            logger.info("Session summary generated: %s", result[:80])
            return result
    except Exception as exc:
        logger.warning("Session summary LLM failed, using fallback: %s", exc)

    return _fallback_summary(messages)


def _fallback_summary(messages: list[dict]) -> str:
    if not messages:
        return "No messages in this session."
    last = messages[-1]
    snippet = last["text_content"][:100]
    if len(last["text_content"]) > 100:
        snippet += "..."
    return f"Last message ({last['role']}): {snippet}"
