"""
LLM-backed Operator using OpenAI-compatible function calling.

The Operator receives the user's message plus context (available agents,
active sessions) and decides whether to route, resume, or just chat.

Supports any OpenAI-compatible API via the base_url parameter (read from
the Operator's Agent DB row).
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field

from app.services.llm.openai import _get_client

logger = logging.getLogger(__name__)


# ── Tool definitions ────────────────────────────────────────────────────

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "connect_to_agent",
            "description": "Connect the user to a specific agent. Use this when the user wants to talk to an agent.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_name": {
                        "type": "string",
                        "description": "The name of the agent to connect to (e.g. 'Vanto', 'Gemini', 'Claude').",
                    }
                },
                "required": ["agent_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "resume_session",
            "description": "Resume a specific previous session by its ID. Use when the user wants to continue a particular past conversation.",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "The session ID to resume.",
                    }
                },
                "required": ["session_id"],
            },
        },
    },
]


# ── Result types ────────────────────────────────────────────────────────

@dataclass
class OperatorResult:
    """Result from the Operator LLM."""
    text: str | None = None              # Conversational reply (if any)
    tool_call: str | None = None         # "connect_to_agent" | "resume_session" | None
    tool_args: dict = field(default_factory=dict)
    assistant_message: dict | None = None  # Raw assistant message for history


# ── Core call ───────────────────────────────────────────────────────────

def _format_session_line(s: dict) -> str:
    name_part = f'"{s["name"]}"' if s.get("name") else "(unnamed)"
    summary_part = f" -- {s['summary']}" if s.get("summary") else ""
    return (
        f"  - {s['agent_name']}: {name_part} "
        f"(status: {s['status']}, session_id: {s['session_id']}, "
        f"last active: {s['last_active'][:16]}){summary_part}"
    )


def _build_system_prompt(agents: list[dict], sessions: list[dict]) -> str:
    lines = []
    for a in agents:
        status = a.get("status", "unknown")
        if status == "healthy":
            tag = "(available)"
        elif status == "error":
            tag = f"(UNAVAILABLE — {a.get('status_message', 'unknown error')})"
        else:
            tag = "(status unknown)"
        lines.append(f"  - {a['name']}: {a.get('persona_prompt', '')[:80]} {tag}")
    agent_lines = "\n".join(lines)
    if sessions:
        session_lines = "\n".join(_format_session_line(s) for s in sessions)
    else:
        session_lines = "  (none)"

    return f"""You are the Relay Operator — warm, brief, and competent. You route users to agents and help them pick up past sessions.

The user knows how the system works. Don't explain it unless they ask. No hand-holding, no filler. Respond in one sentence unless you're listing options.

AGENTS:
{agent_lines}

SESSIONS:
{session_lines}

RULES:
- User wants an agent → call connect_to_agent (always creates a new session).
- User wants to resume a past session → call resume_session with the session ID.
- Agent names may be misspelled by voice — match to the closest available name.
- Vague request → one short clarifying question.
- UNAVAILABLE agent → one-phrase heads-up, connect anyway if they insist.
- Listing agents or sessions → name and status only, no descriptions.
- Anything else → one warm, short sentence."""


async def call_operator(
    user_text: str,
    agents: list[dict],
    sessions: list[dict],
    lobby_history: list[dict],
    *,
    model: str = "gpt-4o-mini",
    base_url: str | None = None,
    api_key: str | None = None,
) -> OperatorResult:
    """
    Call the Operator LLM. Returns an OperatorResult with either a text
    reply or a tool call to execute.

    Accepts any OpenAI-compatible API via base_url. Model, base_url, and
    api_key are read from the Operator's Agent DB row by the caller.
    """
    client = _get_client(base_url, api_key)
    if client is None:
        logger.warning("Operator LLM: No API key configured, falling back to keyword matching")
        return OperatorResult()  # Signals caller to fall back to keyword matching

    logger.info("Operator LLM: Calling %s with %d history messages", model, len(lobby_history))
    system_prompt = _build_system_prompt(agents, sessions)

    messages = [{"role": "system", "content": system_prompt}]
    messages.extend(lobby_history)
    # Note: lobby_history already contains the current user message
    # (appended by the WS handler before calling handle_lobby_message)

    response = await client.chat.completions.create(
        model=model,
        messages=messages,
        tools=TOOLS,
        tool_choice="auto",
    )

    choice = response.choices[0]
    msg = choice.message

    # Build raw assistant message for history tracking
    assistant_msg: dict = {"role": "assistant"}
    if msg.content:
        assistant_msg["content"] = msg.content
    if msg.tool_calls:
        assistant_msg["tool_calls"] = [
            {
                "id": tc.id,
                "type": "function",
                "function": {"name": tc.function.name, "arguments": tc.function.arguments},
            }
            for tc in msg.tool_calls
        ]

    if msg.tool_calls:
        tc = msg.tool_calls[0]
        args = json.loads(tc.function.arguments)
        logger.info("Operator LLM: Tool call → %s(%s)", tc.function.name, args)
        return OperatorResult(
            text=msg.content,  # May include conversational text alongside the tool call
            tool_call=tc.function.name,
            tool_args=args,
            assistant_message=assistant_msg,
        )

    logger.info("Operator LLM: Text reply → %s", (msg.content or "")[:80])
    return OperatorResult(
        text=msg.content or "I'm here to help. Which agent would you like to talk to?",
        assistant_message=assistant_msg,
    )
