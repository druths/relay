"""Service-layer helpers for ark projects.

The REST passthrough in `api/projects.py` exposes the same operations to
clients; this module pulls the core "talk to ark" logic out so the operator
(which lives server-side) can share it without going through HTTP. The
backend remains the single thin layer between clients and ark — there's no
canonical projects table in Relay.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.agent import Agent
from app.services.agent_manager import resolve_llm_config
from app.services.llm.ark import _server_id_for

logger = logging.getLogger(__name__)


async def _ark_servers(
    db: AsyncSession,
) -> list[tuple[str, str, str | None]]:
    """Distinct ark backends reachable through configured Relay agents.
    Returns [(server_id, base_url, api_key)]."""
    result = await db.execute(
        select(Agent).where(
            Agent.deleted_at.is_(None), Agent.llm_provider == "ark",
        )
    )
    seen: dict[str, tuple[str, str, str | None]] = {}
    for agent in result.scalars().all():
        base_url, api_key = await resolve_llm_config(agent)
        if not base_url:
            continue
        sid = _server_id_for(base_url.rstrip("/"), api_key)
        if sid not in seen:
            seen[sid] = (sid, base_url.rstrip("/"), api_key)
    return list(seen.values())


async def _ark_for_server(
    db: AsyncSession, server_id: str | None,
) -> tuple[str, str, str | None] | None:
    """Resolve `server_id` to its (id, base, key) tuple. Returns the lone
    configured ark when `server_id` is None; returns `None` if ambiguous or
    not found."""
    servers = await _ark_servers(db)
    if not servers:
        return None
    if server_id is None:
        return servers[0] if len(servers) == 1 else None
    for sid, base, key in servers:
        if sid == server_id:
            return sid, base, key
    return None


def _auth_headers(api_key: str | None) -> dict[str, str]:
    return {"Authorization": f"Bearer {api_key}"} if api_key else {}


async def list_all_projects(
    db: AsyncSession, *, include_deleted: bool = False,
) -> list[dict[str, Any]]:
    """Aggregate projects across every configured ark backend. Each entry is
    tagged with `server_id` so subsequent ops can be routed back to the
    right ark."""
    servers = await _ark_servers(db)

    async def _fetch(sid: str, base: str, api_key: str | None) -> list[dict]:
        url = f"{base}/projects"
        params: dict[str, str] = {}
        if include_deleted:
            params["include_deleted"] = "true"
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                resp = await client.get(url, headers=_auth_headers(api_key), params=params)
                resp.raise_for_status()
                data = resp.json()
                projects = data if isinstance(data, list) else data.get("projects", [])
                for p in projects:
                    p["server_id"] = sid
                return projects
        except Exception as exc:
            logger.warning("Project listing failed for ark server=%s: %s", sid, exc)
            return []

    results = await asyncio.gather(*(_fetch(*s) for s in servers))
    aggregated: list[dict] = []
    for batch in results:
        aggregated.extend(batch)
    return aggregated


async def create_project_via_ark(
    db: AsyncSession, *,
    server_id: str | None,
    name: str,
    description: str | None = None,
    project_context: str | None = None,
    root: str | None = None,
) -> dict[str, Any]:
    """POST to ark's `/projects` and return the created record annotated with
    `server_id`. Raises `RuntimeError` on a routing or ark failure so callers
    can surface a useful operator message."""
    resolved = await _ark_for_server(db, server_id)
    if resolved is None:
        # Either no ark configured or ambiguous server_id when there are
        # multiple — surface a clear error string.
        servers = await _ark_servers(db)
        if not servers:
            raise RuntimeError("No ark backend is configured")
        raise RuntimeError(
            f"Multiple ark backends configured "
            f"({', '.join(s[0] for s in servers)}); pick one explicitly"
        )
    sid, base, api_key = resolved

    payload: dict[str, Any] = {"name": name}
    if description:
        payload["description"] = description
    if project_context:
        payload["project_context"] = project_context
    if root:
        payload["root"] = root

    url = f"{base}/projects"
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(url, headers=_auth_headers(api_key), json=payload)
    if resp.status_code >= 400:
        raise RuntimeError(f"ark refused project creation: {resp.text}")
    out = resp.json()
    out["server_id"] = sid
    return out


async def resolve_project_by_name(
    db: AsyncSession, name: str,
) -> dict[str, Any] | None:
    """Find a project by case-insensitive name across every ark backend.
    Returns the project record (with `server_id`) or None if not found.
    Picks the most-recently-created on tie."""
    projects = await list_all_projects(db)
    target = name.strip().lower()
    matches = [p for p in projects if (p.get("name") or "").strip().lower() == target]
    if not matches:
        return None
    # ark's `created_at` is an int (epoch ms); fall back to 0 when missing
    # so the sort key stays homogeneous.
    matches.sort(key=lambda p: p.get("created_at") or 0, reverse=True)
    return matches[0]
