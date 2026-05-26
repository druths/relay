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
                    "project_name": {
                        "type": "string",
                        "description": (
                            "Optional name of an ark project to bind the new session to "
                            "(e.g. 'marketing-brochure'). Only valid for ark agents. The "
                            "agent must be configured on the same ark backend as the project."
                        ),
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
    {
        "type": "function",
        "function": {
            "name": "create_project",
            "description": (
                "Create a new ark project — a shared, user-visible working directory "
                "that one or more sessions can be bound to. Use when the user says "
                "something like 'start a project for X' or 'create a new project called Y'. "
                "Does NOT also start a session — after creation, the user can ask to "
                "connect to an agent within it."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Short kebab-case project name (e.g. 'marketing-brochure'). Must be unique among active projects.",
                    },
                    "description": {
                        "type": "string",
                        "description": "Optional one-line description.",
                    },
                    "project_context": {
                        "type": "string",
                        "description": "Optional notes / guidelines injected into the agent's system prompt for every session in this project.",
                    },
                    "ark_server_id": {
                        "type": "string",
                        "description": "Required when multiple ark backends are configured — pick the one to host this project. Omit if there's only one ark.",
                    },
                },
                "required": ["name"],
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


def _build_system_prompt(
    agents: list[dict], sessions: list[dict], projects: list[dict] | None = None,
    ark_servers: list[str] | None = None,
) -> str:
    lines = []
    for a in agents:
        status = a.get("status", "unknown")
        if status == "healthy":
            tag = "(available)"
        elif status == "error":
            tag = f"(UNAVAILABLE — {a.get('status_message', 'unknown error')})"
        else:
            tag = "(status unknown)"
        # Annotate ark agents with their ark server_id so the operator knows
        # which projects are addressable per-agent. Non-ark agents have no
        # server_id and can't be bound to a project.
        server = f" [ark:{a['ark_server_id']}]" if a.get("ark_server_id") else ""
        lines.append(f"  - {a['name']}{server}: {a.get('persona_prompt', '')[:80]} {tag}")
    agent_lines = "\n".join(lines)
    if sessions:
        session_lines = "\n".join(_format_session_line(s) for s in sessions)
    else:
        session_lines = "  (none)"

    # Project rendering: one line per project, tagged with the ark server it
    # lives on so the operator can match project → eligible agents.
    if projects:
        proj_lines = "\n".join(
            f"  - {p['name']} [ark:{p['server_id']}]"
            + (f" — {p['description']}" if p.get("description") else "")
            for p in projects
        )
    else:
        proj_lines = "  (none)"

    # Collect existing labels from sessions for context
    all_labels = sorted({l for s in sessions for l in s.get("labels", [])})
    labels_lines = ", ".join(all_labels) if all_labels else "(none)"

    multi_ark = bool(ark_servers and len(ark_servers) > 1)
    server_rule = (
        "- create_project: multiple ark backends are configured "
        f"({', '.join(ark_servers or [])}); pass ark_server_id explicitly."
        if multi_ark
        else "- create_project: a single ark backend is configured; ark_server_id can be omitted."
    )

    return f"""You are the Relay Operator — warm, brief, and competent. You route users to agents and help them pick up past sessions.

The user knows how the system works. Don't explain it unless they ask. No hand-holding, no filler. Respond in one sentence unless you're listing options.

AGENTS:
{agent_lines}

SESSIONS:
{session_lines}

PROJECTS:
{proj_lines}

EXISTING LABELS:
  {labels_lines}

RULES:
- User wants an agent → call connect_to_agent (always creates a new session).
- If the user mentions a category or label for the session (e.g. "under builds", "in the frontend category"), pass it in the labels parameter of connect_to_agent.
- If the user asks to connect to an agent "in" or "for" a project (e.g. "connect to Scribe in the brochure project"), pass project_name. Only ark agents can be bound; if the requested agent isn't ark or isn't on the project's ark server, connect without the binding and mention the mismatch in one phrase.
- User wants to resume a past session → call resume_session with the session ID.
- User wants to start a new project ("create a project for X", "spin up a project called Y") → call create_project. Do NOT also connect to an agent in the same turn; let the user choose the agent next.
{server_rule}
- Agent names may be misspelled by voice — match to the closest available name.
- Vague request → one short clarifying question.
- UNAVAILABLE agent → one-phrase heads-up, connect anyway if they insist.
- Listing agents, sessions, or projects → name and status only, no descriptions.
- Anything else → one warm, short sentence."""


async def call_operator(
    user_text: str,
    agents: list[dict],
    sessions: list[dict],
    lobby_history: list[dict],
    *,
    projects: list[dict] | None = None,
    ark_servers: list[str] | None = None,
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
    system_prompt = _build_system_prompt(agents, sessions, projects, ark_servers)

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
