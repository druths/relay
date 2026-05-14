"""LLM provider factory."""

from __future__ import annotations

from app.services.llm.base import LLMProvider


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
