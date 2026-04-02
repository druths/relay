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

from app.services.llm.anthropic import _get_client as _get_anthropic_client
from app.services.llm.openai import _get_client as _get_openai_client

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
                    },
                    "labels": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional labels/categories to apply to the new session (e.g. ['builds', 'frontend']).",
                    },
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
    labels = s.get("labels", [])
    labels_part = f" [{', '.join(labels)}]" if labels else ""
    return (
        f"  - {s['agent_name']}: {name_part}{labels_part} "
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

    # Collect existing labels from sessions for context
    all_labels = sorted({l for s in sessions for l in s.get("labels", [])})
    labels_lines = ", ".join(all_labels) if all_labels else "(none)"

    return f"""You are the Relay Operator — warm, brief, and competent. You route users to agents and help them pick up past sessions.

The user knows how the system works. Don't explain it unless they ask. No hand-holding, no filler. Respond in one sentence unless you're listing options.

AGENTS:
{agent_lines}

SESSIONS:
{session_lines}

EXISTING LABELS:
  {labels_lines}

RULES:
- User wants an agent → call connect_to_agent (always creates a new session).
- If the user mentions a category or label for the session (e.g. "under builds", "in the frontend category"), pass it in the labels parameter of connect_to_agent.
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
    provider: str = "openai",
    model: str = "gpt-4o-mini",
    base_url: str | None = None,
    api_key: str | None = None,
) -> OperatorResult:
    """
    Call the Operator LLM. Returns an OperatorResult with either a text
    reply or a tool call to execute.

    Dispatches to the Anthropic or OpenAI client based on provider.
    """
    system_prompt = _build_system_prompt(agents, sessions)

    if provider == "anthropic":
        return await _call_anthropic(model, api_key, system_prompt, lobby_history)
    else:
        return await _call_openai(model, base_url, api_key, system_prompt, lobby_history)


async def _call_openai(
    model: str,
    base_url: str | None,
    api_key: str | None,
    system_prompt: str,
    lobby_history: list[dict],
) -> OperatorResult:
    """Operator call via OpenAI-compatible API."""
    client = _get_openai_client(base_url, api_key)
    if client is None:
        logger.warning("Operator LLM: No OpenAI API key configured, falling back to keyword matching")
        return OperatorResult()

    logger.info("Operator LLM (openai): Calling %s with %d history messages", model, len(lobby_history))

    messages = [{"role": "system", "content": system_prompt}]
    messages.extend(lobby_history)

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
            text=msg.content,
            tool_call=tc.function.name,
            tool_args=args,
            assistant_message=assistant_msg,
        )

    logger.info("Operator LLM: Text reply → %s", (msg.content or "")[:80])
    return OperatorResult(
        text=msg.content or "I'm here to help. Which agent would you like to talk to?",
        assistant_message=assistant_msg,
    )


# ── Anthropic tool format ──────────────────────────────────────────────

ANTHROPIC_TOOLS = [
    {
        "name": tool["function"]["name"],
        "description": tool["function"]["description"],
        "input_schema": tool["function"]["parameters"],
    }
    for tool in TOOLS
]


def _ensure_alternation(messages: list[dict]) -> list[dict]:
    """Merge consecutive same-role messages (Anthropic requires strict alternation).
    Also filters out system/tool messages that Anthropic doesn't support inline."""
    clean = []
    for msg in messages:
        role = msg.get("role", "")
        # Map tool results to user messages for Anthropic
        if role == "tool":
            content = msg.get("content", "")
            tool_call_id = msg.get("tool_call_id", "")
            entry = {
                "role": "user",
                "content": [{"type": "tool_result", "tool_use_id": tool_call_id, "content": content}],
            }
            clean.append(entry)
            continue
        if role == "system":
            continue
        # Convert assistant messages with tool_calls to Anthropic format
        if role == "assistant" and "tool_calls" in msg:
            content_blocks = []
            if msg.get("content"):
                content_blocks.append({"type": "text", "text": msg["content"]})
            for tc in msg["tool_calls"]:
                content_blocks.append({
                    "type": "tool_use",
                    "id": tc["id"],
                    "name": tc["function"]["name"],
                    "input": json.loads(tc["function"]["arguments"]) if isinstance(tc["function"]["arguments"], str) else tc["function"]["arguments"],
                })
            clean.append({"role": "assistant", "content": content_blocks})
            continue
        clean.append({"role": role, "content": msg.get("content", "")})

    # Merge consecutive same-role messages
    if not clean:
        return clean
    merged = [clean[0]]
    for msg in clean[1:]:
        if msg["role"] == merged[-1]["role"]:
            # Merge text content
            prev = merged[-1].get("content", "")
            curr = msg.get("content", "")
            if isinstance(prev, str) and isinstance(curr, str):
                merged[-1]["content"] = prev + "\n" + curr
            else:
                # For complex content blocks, just keep them separate by inserting a spacer
                merged.append(msg)
        else:
            merged.append(msg)

    # Anthropic requires first message to be "user"
    if merged and merged[0]["role"] != "user":
        merged.insert(0, {"role": "user", "content": "(conversation start)"})

    return merged


async def _call_anthropic(
    model: str,
    api_key: str | None,
    system_prompt: str,
    lobby_history: list[dict],
) -> OperatorResult:
    """Operator call via Anthropic Messages API with tool use."""
    client = _get_anthropic_client(api_key)
    if client is None:
        logger.warning("Operator LLM: No Anthropic API key configured, falling back to keyword matching")
        return OperatorResult()

    logger.info("Operator LLM (anthropic): Calling %s with %d history messages", model, len(lobby_history))

    messages = _ensure_alternation(lobby_history)

    response = await client.messages.create(
        model=model,
        system=system_prompt,
        messages=messages,
        tools=ANTHROPIC_TOOLS,
        max_tokens=1024,
    )

    # Extract text and tool use from response content blocks
    text_parts = []
    tool_call = None
    tool_args = {}
    tool_use_id = None

    for block in response.content:
        if block.type == "text":
            text_parts.append(block.text)
        elif block.type == "tool_use":
            tool_call = block.name
            tool_args = block.input
            tool_use_id = block.id

    text = " ".join(text_parts).strip() or None

    # Build assistant message for lobby history (in OpenAI format for consistency)
    assistant_msg: dict = {"role": "assistant"}
    if text:
        assistant_msg["content"] = text
    if tool_call and tool_use_id:
        assistant_msg["tool_calls"] = [
            {
                "id": tool_use_id,
                "type": "function",
                "function": {"name": tool_call, "arguments": json.dumps(tool_args)},
            }
        ]

    if tool_call:
        logger.info("Operator LLM: Tool call → %s(%s)", tool_call, tool_args)
        return OperatorResult(
            text=text,
            tool_call=tool_call,
            tool_args=tool_args,
            assistant_message=assistant_msg,
        )

    logger.info("Operator LLM: Text reply → %s", (text or "")[:80])
    return OperatorResult(
        text=text or "I'm here to help. Which agent would you like to talk to?",
        assistant_message=assistant_msg,
    )
