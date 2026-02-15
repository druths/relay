"""LLM provider factory."""

from __future__ import annotations

from app.services.llm.base import LLMProvider


def get_provider(provider_name: str, base_url: str | None = None) -> LLMProvider | None:
    """Return a provider instance, or None if not configured.

    Supports:
        "openai"    — OpenAI API (default)
        "anthropic" — Anthropic API
        "gemini"    — Google Gemini API
        "ollama"    — Ollama via OpenAI-compatible API (default base_url: http://localhost:11434/v1)
        Any other   — treated as OpenAI-compatible if base_url is provided
    """
    if provider_name == "openai":
        from app.services.llm.openai import OpenAIProvider, _get_client
        if _get_client(base_url) is None:
            return None
        return OpenAIProvider(base_url=base_url)

    if provider_name == "anthropic":
        from app.services.llm.anthropic import AnthropicProvider, _get_client
        if _get_client() is None:
            return None
        return AnthropicProvider()

    if provider_name == "gemini":
        from app.services.llm.gemini import GeminiProvider, _get_client as _get_gemini_client
        if _get_gemini_client() is None:
            return None
        return GeminiProvider()

    if provider_name == "ollama":
        from app.services.llm.openai import OpenAIProvider
        url = base_url or "http://localhost:11434/v1"
        return OpenAIProvider(base_url=url)

    # Unknown provider with a base_url — try OpenAI-compatible
    if base_url:
        from app.services.llm.openai import OpenAIProvider
        return OpenAIProvider(base_url=base_url)

    return None
