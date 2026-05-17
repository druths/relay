"""LLM provider factory and UI schema registry.

Schemas here are the single source of truth for the client picker — see
`/v1/agents/llm/providers`. To add or change a provider, edit the
PROVIDER_SCHEMAS list below and (if needed) the get_provider branch.
"""

from __future__ import annotations

from app.services.llm.base import LLMProvider


PROVIDER_SCHEMAS: list[dict] = [
    {
        "id": "openai",
        "label": "OpenAI",
        "fields": [
            {"key": "llm_api_key", "label": "API Key", "type": "password",
             "placeholder": "sk-…", "required": False,
             "platform_key": "llm_openai_api_key"},
            {"key": "llm_model", "label": "Model", "type": "text",
             "placeholder": "gpt-4o-mini", "required": True},
        ],
    },
    {
        "id": "anthropic",
        "label": "Anthropic",
        "fields": [
            {"key": "llm_api_key", "label": "API Key", "type": "password",
             "placeholder": "sk-ant-…",
             "platform_key": "llm_anthropic_api_key"},
            {"key": "llm_model", "label": "Model", "type": "text",
             "placeholder": "claude-sonnet-4-5-20250929", "required": True},
        ],
    },
    {
        "id": "gemini",
        "label": "Gemini",
        "fields": [
            {"key": "llm_api_key", "label": "API Key", "type": "password",
             "placeholder": "AIza…",
             "platform_key": "llm_gemini_api_key"},
            {"key": "llm_model", "label": "Model", "type": "text",
             "placeholder": "gemini-2.5-flash", "required": True},
        ],
    },
    {
        "id": "ollama",
        "label": "Ollama",
        "fields": [
            {"key": "llm_base_url", "label": "Base URL", "type": "text",
             "placeholder": "http://localhost:11434/v1",
             "platform_key": "llm_ollama_base_url"},
            {"key": "llm_model", "label": "Model", "type": "text",
             "placeholder": "llama3", "required": True},
        ],
    },
    {
        "id": "openclaw",
        "label": "OpenClaw",
        "fields": [
            {"key": "llm_base_url", "label": "Gateway URL", "type": "text",
             "placeholder": "http://localhost:18789", "required": True,
             "platform_key": "llm_openclaw_base_url"},
            {"key": "llm_model", "label": "Agent ID", "type": "text",
             "placeholder": "main", "required": True},
            {"key": "llm_api_key", "label": "Auth Token", "type": "password",
             "placeholder": "(optional)",
             "platform_key": "llm_openclaw_api_key"},
        ],
    },
    {
        "id": "openai-compatible",
        "label": "OpenAI-Compatible",
        "fields": [
            {"key": "llm_base_url", "label": "Base URL", "type": "text",
             "placeholder": "https://api.example.com/v1", "required": True},
            {"key": "llm_api_key", "label": "API Key", "type": "password",
             "placeholder": "(optional)"},
            {"key": "llm_model", "label": "Model", "type": "text",
             "placeholder": "model-name", "required": True},
        ],
    },
    {
        "id": "ark",
        "label": "Ark",
        "fields": [
            {"key": "llm_base_url", "label": "Server URL", "type": "text",
             "placeholder": "http://localhost:7777", "required": True,
             "platform_key": "llm_ark_base_url"},
            {"key": "llm_model", "label": "Agent Name", "type": "text",
             "placeholder": "assistant", "required": True},
            {"key": "llm_api_key", "label": "Auth Token", "type": "password",
             "placeholder": "(shared bearer secret)",
             "platform_key": "llm_ark_api_key"},
        ],
    },
]


def list_provider_schemas() -> list[dict]:
    return PROVIDER_SCHEMAS


def get_provider(
    provider_name: str,
    base_url: str | None = None,
    api_key: str | None = None,
) -> LLMProvider | None:
    """Return a provider instance, or None if not configured.

    If *api_key* is supplied it takes precedence over the env-var default.

    Supports:
        "openai"    — OpenAI API (default)
        "anthropic" — Anthropic API
        "gemini"    — Google Gemini API
        "openclaw"  — OpenClaw gateway via OpenAI-compatible API (requires base_url)
        "ollama"    — Ollama via OpenAI-compatible API (default base_url: http://localhost:11434/v1)
        Any other   — treated as OpenAI-compatible if base_url is provided
    """
    if provider_name == "openai":
        from app.services.llm.openai import OpenAIProvider, _get_client
        if _get_client(base_url, api_key) is None:
            return None
        return OpenAIProvider(base_url=base_url, api_key=api_key)

    if provider_name == "anthropic":
        from app.services.llm.anthropic import AnthropicProvider, _get_client
        if _get_client(api_key) is None:
            return None
        return AnthropicProvider(api_key=api_key)

    if provider_name == "gemini":
        from app.services.llm.gemini import GeminiProvider, _get_client as _get_gemini_client
        if _get_gemini_client(api_key) is None:
            return None
        return GeminiProvider(api_key=api_key)

    if provider_name == "openclaw":
        if not base_url:
            return None
        from app.services.llm.openclaw import OpenClawProvider
        return OpenClawProvider(base_url=base_url, api_key=api_key)

    if provider_name == "ark":
        if not base_url:
            return None
        from app.services.llm.ark import ArkProvider
        return ArkProvider(base_url=base_url, api_key=api_key)

    if provider_name == "ollama":
        from app.services.llm.openai import OpenAIProvider
        url = base_url or "http://localhost:11434/v1"
        return OpenAIProvider(base_url=url, api_key=api_key)

    # Unknown provider with a base_url — try OpenAI-compatible
    if base_url:
        from app.services.llm.openai import OpenAIProvider
        return OpenAIProvider(base_url=base_url, api_key=api_key)

    return None
