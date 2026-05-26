"""Passthrough to ark's project + workspace REST surface.

Ark is the source of truth for projects; Relay does not mirror the projects
table. Each Relay request is forwarded to the appropriate ark server. Where
the user has multiple ark servers configured (different agents on different
arks), single-project ops require `?server=<server_id>` to disambiguate;
the aggregate listing tags every project with its `server_id` so clients
can pass it back.

Workspace endpoints are agent-scoped — the agent's `llm_base_url` /
`llm_api_key` determine which ark hosts the workspace.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.db.database import get_db
from app.models.agent import Agent
from app.services.agent_manager import resolve_llm_config
from app.services.llm.ark import _server_id_for
from app.services.projects import (
    _ark_servers,
    create_project_via_ark,
    list_all_projects,
)

logger = logging.getLogger(__name__)


projects_router = APIRouter(
    prefix="/v1/projects",
    tags=["projects"],
    dependencies=[Depends(get_current_user)],
)
workspaces_router = APIRouter(
    prefix="/v1/agents",
    tags=["workspaces"],
    dependencies=[Depends(get_current_user)],
)


# ── ark server resolution ──────────────────────────────────────────────


async def _ark_for_server(
    db: AsyncSession, server_id: str | None,
) -> tuple[str, str, str | None]:
    """Return (server_id, base_url, api_key) for the given server_id. If
    `server_id` is None and only one ark is configured, returns that one.
    Raises 400 otherwise."""
    servers = await _ark_servers(db)
    if not servers:
        raise HTTPException(status_code=503, detail="No ark backend configured")
    if server_id is None:
        if len(servers) == 1:
            return servers[0]
        raise HTTPException(
            status_code=400,
            detail="Multiple ark servers configured — pass ?server=<server_id>",
        )
    for sid, base, key in servers:
        if sid == server_id:
            return sid, base, key
    raise HTTPException(status_code=404, detail=f"Unknown ark server {server_id}")


async def _ark_for_agent(
    db: AsyncSession, agent_id: str,
) -> tuple[str, str, str | None, Agent]:
    """Return (server_id, base_url, api_key, agent) for the given agent."""
    import uuid as _uuid
    try:
        aid = _uuid.UUID(agent_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid agent_id")
    result = await db.execute(
        select(Agent).where(
            Agent.agent_id == aid,
            Agent.deleted_at.is_(None),
        )
    )
    agent = result.scalar_one_or_none()
    if agent is None:
        raise HTTPException(status_code=404, detail="Agent not found")
    if agent.llm_provider != "ark":
        raise HTTPException(
            status_code=400, detail="Agent is not ark-backed",
        )
    base_url, api_key = await resolve_llm_config(agent)
    if not base_url:
        raise HTTPException(status_code=500, detail="Agent missing base_url")
    sid = _server_id_for(base_url.rstrip("/"), api_key)
    return sid, base_url.rstrip("/"), api_key, agent


def _ark_agent_name(agent: Agent) -> str:
    """The `name` ark expects on path. Mirrors files.py:_ark_agent_name."""
    model = (agent.llm_model or "").strip()
    if model.startswith("ark:"):
        return model[len("ark:"):]
    return model or agent.name


def _auth_headers(api_key: str | None) -> dict[str, str]:
    return {"Authorization": f"Bearer {api_key}"} if api_key else {}


# ── Project CRUD ───────────────────────────────────────────────────────


class ProjectIn(BaseModel):
    name: str
    description: str | None = None
    project_context: str | None = None
    root: str | None = None


class ProjectUpdate(BaseModel):
    name: str | None = None
    description: str | None = None
    project_context: str | None = None


@projects_router.get("/servers")
async def list_ark_servers(db: AsyncSession = Depends(get_db)) -> list[dict[str, str]]:
    """Distinct ark backends reachable through configured agents. The
    ProjectManager UI uses this to populate the server picker when creating
    a project (with >1 ark configured)."""
    servers = await _ark_servers(db)
    return [{"server_id": sid, "base_url": base} for sid, base, _ in servers]


@projects_router.get("")
async def list_projects(
    db: AsyncSession = Depends(get_db),
    include_deleted: bool = Query(False),
) -> list[dict[str, Any]]:
    """Aggregate projects from every configured ark backend. Each entry is
    tagged with `server_id` so subsequent single-project ops can be routed."""
    return await list_all_projects(db, include_deleted=include_deleted)


@projects_router.post("", status_code=201)
async def create_project(
    body: ProjectIn,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    try:
        return await create_project_via_ark(
            db, server_id=server,
            name=body.name,
            description=body.description,
            project_context=body.project_context,
            root=body.root,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@projects_router.get("/{project_id}")
async def get_project(
    project_id: str,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    sid, base, api_key = await _ark_for_server(db, server)
    url = f"{base}/projects/{project_id}"
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(url, headers=_auth_headers(api_key))
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    out = resp.json()
    out["server_id"] = sid
    return out


@projects_router.put("/{project_id}")
async def update_project(
    project_id: str,
    body: ProjectUpdate,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    sid, base, api_key = await _ark_for_server(db, server)
    url = f"{base}/projects/{project_id}"
    payload = body.model_dump(exclude_none=True)
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.put(url, headers=_auth_headers(api_key), json=payload)
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    out = resp.json()
    out["server_id"] = sid
    return out


@projects_router.delete("/{project_id}", status_code=204)
async def delete_project(
    project_id: str,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key = await _ark_for_server(db, server)
    url = f"{base}/projects/{project_id}"
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.delete(url, headers=_auth_headers(api_key))
    if resp.status_code >= 400 and resp.status_code != 204:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return Response(status_code=204)


# ── Filesystem passthroughs ────────────────────────────────────────────


async def _proxy_fs_get(base: str, api_key: str | None, *, suffix: str) -> Response:
    """Pass through a filesystem GET to ark. Streams bytes for files; returns
    JSON for directory listings (ark sets the right Content-Type for us)."""
    url = f"{base}{suffix}"
    client = httpx.AsyncClient(timeout=120)
    try:
        req = client.build_request("GET", url, headers=_auth_headers(api_key))
        resp = await client.send(req, stream=True)
    except httpx.HTTPError as exc:
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Ark unreachable: {exc}")
    if resp.status_code >= 400:
        body = (await resp.aread()).decode("utf-8", errors="replace")
        await resp.aclose()
        await client.aclose()
        raise HTTPException(status_code=resp.status_code, detail=body)
    # Hand the open response back to FastAPI as a stream so binaries don't
    # buffer in memory.
    async def _iter():
        try:
            async for chunk in resp.aiter_bytes():
                yield chunk
        finally:
            await resp.aclose()
            await client.aclose()
    headers = {}
    for h in ("content-type", "content-length", "content-disposition"):
        if h in resp.headers:
            headers[h] = resp.headers[h]
    return StreamingResponse(_iter(), status_code=resp.status_code, headers=headers)


async def _proxy_fs_write(
    base: str, api_key: str | None, *, suffix: str, body: bytes,
) -> dict[str, Any]:
    url = f"{base}{suffix}"
    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.put(url, headers=_auth_headers(api_key), content=body)
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return resp.json() if resp.content else {}


async def _proxy_fs_delete(base: str, api_key: str | None, *, suffix: str) -> None:
    url = f"{base}{suffix}"
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.delete(url, headers=_auth_headers(api_key))
    if resp.status_code >= 400 and resp.status_code != 204:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)


async def _proxy_fs_mkdir(
    base: str, api_key: str | None, *, suffix: str,
) -> dict[str, Any]:
    url = f"{base}{suffix}"
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(url, headers=_auth_headers(api_key), params={"op": "mkdir"})
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return resp.json() if resp.content else {}


# ── Project filesystem ─────────────────────────────────────────────────


@projects_router.get("/{project_id}/files")
async def list_project_root(
    project_id: str,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key = await _ark_for_server(db, server)
    return await _proxy_fs_get(base, api_key, suffix=f"/projects/{project_id}/files")


@projects_router.get("/{project_id}/files/{path:path}")
async def project_file_or_listing(
    project_id: str,
    path: str,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key = await _ark_for_server(db, server)
    return await _proxy_fs_get(
        base, api_key, suffix=f"/projects/{project_id}/files/{path}",
    )


@projects_router.put("/{project_id}/files/{path:path}")
async def project_file_put(
    project_id: str,
    path: str,
    request: Request,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key = await _ark_for_server(db, server)
    body = await request.body()
    return await _proxy_fs_write(
        base, api_key,
        suffix=f"/projects/{project_id}/files/{path}",
        body=body,
    )


@projects_router.delete("/{project_id}/files/{path:path}", status_code=204)
async def project_file_delete(
    project_id: str,
    path: str,
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key = await _ark_for_server(db, server)
    await _proxy_fs_delete(
        base, api_key, suffix=f"/projects/{project_id}/files/{path}",
    )
    return Response(status_code=204)


@projects_router.post("/{project_id}/files/{path:path}")
async def project_file_mkdir(
    project_id: str,
    path: str,
    op: str = Query(..., description="Must be 'mkdir'"),
    server: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    if op != "mkdir":
        raise HTTPException(status_code=400, detail="Only ?op=mkdir is supported")
    _sid, base, api_key = await _ark_for_server(db, server)
    return await _proxy_fs_mkdir(
        base, api_key, suffix=f"/projects/{project_id}/files/{path}",
    )


# ── Workspace filesystem (per-agent) ───────────────────────────────────


@workspaces_router.get("/{agent_id}/workspace/files")
async def list_workspace_root(
    agent_id: str,
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key, agent = await _ark_for_agent(db, agent_id)
    name = _ark_agent_name(agent)
    return await _proxy_fs_get(base, api_key, suffix=f"/agents/{name}/files")


@workspaces_router.get("/{agent_id}/workspace/files/{path:path}")
async def workspace_file_or_listing(
    agent_id: str,
    path: str,
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key, agent = await _ark_for_agent(db, agent_id)
    name = _ark_agent_name(agent)
    return await _proxy_fs_get(base, api_key, suffix=f"/agents/{name}/files/{path}")


@workspaces_router.put("/{agent_id}/workspace/files/{path:path}")
async def workspace_file_put(
    agent_id: str,
    path: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key, agent = await _ark_for_agent(db, agent_id)
    name = _ark_agent_name(agent)
    body = await request.body()
    return await _proxy_fs_write(
        base, api_key, suffix=f"/agents/{name}/files/{path}", body=body,
    )


@workspaces_router.delete("/{agent_id}/workspace/files/{path:path}", status_code=204)
async def workspace_file_delete(
    agent_id: str,
    path: str,
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key, agent = await _ark_for_agent(db, agent_id)
    name = _ark_agent_name(agent)
    await _proxy_fs_delete(base, api_key, suffix=f"/agents/{name}/files/{path}")
    return Response(status_code=204)


@workspaces_router.post("/{agent_id}/workspace/files/{path:path}")
async def workspace_file_mkdir(
    agent_id: str,
    path: str,
    op: str = Query(..., description="Must be 'mkdir'"),
    db: AsyncSession = Depends(get_db),
):
    if op != "mkdir":
        raise HTTPException(status_code=400, detail="Only ?op=mkdir is supported")
    _sid, base, api_key, agent = await _ark_for_agent(db, agent_id)
    name = _ark_agent_name(agent)
    return await _proxy_fs_mkdir(
        base, api_key, suffix=f"/agents/{name}/files/{path}",
    )
