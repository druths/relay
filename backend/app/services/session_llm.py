"""
LLM utilities for session naming and summarization.

Uses the Operator's LLM config (model, base_url) from the DB.
"""

from __future__ import annotations

import logging

from app.services.llm.openai import _get_client

logger = logging.getLogger(__name__)


async def generate_session_name(
    first_user_message: str,
    first_agent_response: str,
    agent_name: str,
    *,
    model: str = "gpt-4o-mini",
    base_url: str | None = None,
) -> str:
    """Generate a short 3-5 word title for a session from the first exchange."""
    client = _get_client(base_url)
    if client is None:
        return _fallback_name(first_user_message)

    try:
        response = await client.chat.completions.create(
            model=model,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "Generate a short title (3-5 words) that captures the topic of this conversation. "
                        "Return ONLY the title, no quotes, no punctuation at the end."
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        f"User said to {agent_name}: \"{first_user_message}\"\n"
                        f"{agent_name} replied: \"{first_agent_response[:200]}\""
                    ),
                },
            ],
            max_tokens=20,
            temperature=0.3,
        )
        name = response.choices[0].message.content.strip()
        logger.info("Session name generated: %s", name)
        return name[:200] if name else _fallback_name(first_user_message)
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
    model: str = "gpt-4o-mini",
    base_url: str | None = None,
) -> str:
    """Generate a 1-2 sentence summary of the session conversation."""
    client = _get_client(base_url)
    if client is None:
        return _fallback_summary(messages)

    recent = messages[-15:]
    transcript = "\n".join(
        f"{m['role']}: {m['text_content'][:150]}" for m in recent
    )

    try:
        response = await client.chat.completions.create(
            model=model,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "Summarize this conversation in 1-2 sentences. "
                        "Focus on what was discussed and any conclusions reached. "
                        "Return ONLY the summary."
                    ),
                },
                {"role": "user", "content": transcript},
            ],
            max_tokens=100,
            temperature=0.3,
        )
        summary = response.choices[0].message.content.strip()
        logger.info("Session summary generated: %s", summary[:80])
        return summary if summary else _fallback_summary(messages)
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
