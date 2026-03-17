"""
Operator logic — the system agent that routes user intent.

V1 uses keyword-based matching. This module is designed to be swapped out
for an LLM-based classifier without changing the Conversation Manager.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum


class Intent(Enum):
    CONNECT = "connect"
    RESUME = "resume"
    LIST_AGENTS = "list_agents"
    LIST_SESSIONS = "list_sessions"
    DISCONNECT = "disconnect"
    GENERAL = "general"


@dataclass
class ParsedIntent:
    intent: Intent
    target_agent: str | None = None
    session_hint: str | None = None


# Patterns checked in order; first match wins
_PATTERNS: list[tuple[re.Pattern, Intent, str | None]] = [
    (re.compile(r"connect\s+(?:me\s+)?(?:to\s+)?(\w+)", re.I), Intent.CONNECT, None),
    (re.compile(r"(?:talk|speak|switch)\s+(?:to|with)\s+(\w+)", re.I), Intent.CONNECT, None),
    (re.compile(r"continue\s+(?:with\s+)?(\w+)", re.I), Intent.RESUME, None),
    (re.compile(r"resume\s+(?:with\s+)?(\w+)", re.I), Intent.RESUME, None),
    (re.compile(r"(?:who|what|list).*agents?", re.I), Intent.LIST_AGENTS, None),
    (re.compile(r"(?:my|list|show).*sessions?", re.I), Intent.LIST_SESSIONS, None),
    (re.compile(r"^operator\.?$", re.I), Intent.DISCONNECT, None),
]


def parse_intent(text: str) -> ParsedIntent:
    """Parse user text into a structured intent for the Conversation Manager."""
    for pattern, intent, _ in _PATTERNS:
        m = pattern.search(text)
        if m:
            target = m.group(1) if m.lastindex and m.lastindex >= 1 else None
            return ParsedIntent(intent=intent, target_agent=target)
    return ParsedIntent(intent=Intent.GENERAL)


def operator_greeting() -> str:
    return "Operator here."


def operator_connect_message(agent_name: str) -> str:
    return f"Connecting to {agent_name}."


def operator_not_found(agent_name: str) -> str:
    return f"Don't have a '{agent_name}' — who do you need?"


def operator_list_agents(names: list[str]) -> str:
    if not names:
        return "No agents available."
    return "Available: " + ", ".join(names) + "."


def operator_disconnect_message() -> str:
    return "Operator here."
