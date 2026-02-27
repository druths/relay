"""Shared API utilities."""

from __future__ import annotations


def mask_api_key(key: str | None) -> str | None:
    """Return a masked version of an API key for safe display, or None."""
    if not key:
        return None
    if len(key) <= 4:
        return "••••"
    return "••••" + key[-4:]
