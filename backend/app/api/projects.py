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


# ── File-type probe ────────────────────────────────────────────────

# Bytes to sniff before classifying. 8KB is what `git` uses for its own
# binary-vs-text check — enough to catch NULL bytes in a header, not so
# much that we punish files hosted on slow storage.
_PROBE_BYTES = 8192

# Anything above this share of non-printable ASCII in the probe window
# gets called "binary." Matches git's default heuristic.
_NON_TEXT_RATIO_CUTOFF = 0.30


def _classify_probe_bytes(data: bytes, content_type: str | None) -> str:
    """Return one of "text", "image", "pdf", "binary" based on the first
    few bytes of a file. Prefers Content-Type when it's authoritative
    (image/*, application/pdf); otherwise falls back to a git-style
    byte scan — a NULL byte or a high non-printable ratio → binary."""
    ct = (content_type or "").lower().split(";")[0].strip()
    if ct.startswith("image/"):
        return "image"
    if ct == "application/pdf":
        return "pdf"
    if not data:
        # Empty file — treat as text (empty README, .gitkeep, etc.).
        return "text"
    # PDF magic — some servers serve as octet-stream but the bytes start
    # with %PDF- regardless.
    if data[:5] == b"%PDF-":
        return "pdf"
    # Image magics — quick check for the common ones so a .png served
    # with the wrong Content-Type is still identified.
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image"
    if data[:3] == b"\xff\xd8\xff":
        return "image"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image"
    if data[:4] == b"RIFF" and len(data) > 12 and data[8:12] == b"WEBP":
        return "image"
    # NULL byte in the probe window → definitely binary.
    if b"\x00" in data:
        return "binary"
    # Non-printable ratio — allow common whitespace (\t \n \r \f), reject
    # other control bytes.
    printable = 0
    for b in data:
        if b == 0x09 or b == 0x0A or b == 0x0C or b == 0x0D:
            printable += 1
        elif 0x20 <= b < 0x7F:
            printable += 1
        elif b >= 0x80:
            # UTF-8 continuation / high-bit bytes — count as printable,
            # the strict decode below will reject genuine garbage.
            printable += 1
    if (len(data) - printable) / len(data) > _NON_TEXT_RATIO_CUTOFF:
        return "binary"
    # Final gate: does it decode as UTF-8? Reject if not.
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        # Might be another text encoding but we don't want to guess —
        # anything not UTF-8 gets treated as binary for preview purposes.
        return "binary"
    return "text"


async def _probe_via_ark(
    base: str, api_key: str | None, *, suffix: str,
) -> dict[str, str]:
    """Fetch the first `_PROBE_BYTES` bytes of a file through ark and
    classify them. Uses HTTP Range so we don't pull the whole file just
    to decide."""
    url = f"{base}{suffix}"
    headers = _auth_headers(api_key)
    headers["Range"] = f"bytes=0-{_PROBE_BYTES - 1}"
    async with httpx.AsyncClient(timeout=30) as client:
        try:
            resp = await client.get(url, headers=headers)
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"Ark unreachable: {exc}")
    if resp.status_code >= 400 and resp.status_code != 416:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    data = resp.content or b""
    ct = resp.headers.get("content-type", "")
    kind = _classify_probe_bytes(data, ct)
    return {"kind": kind, "content_type": ct}


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


# ── Rename + zip-download (Relay-side compositions) ───────────────────


async def _ark_listing(
    base: str, api_key: str | None, *, suffix: str,
) -> dict[str, Any]:
    """GET a directory listing — JSON shape per ark's docs/projects.md."""
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(f"{base}{suffix}", headers=_auth_headers(api_key))
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return resp.json()


async def _ark_file_bytes(
    base: str, api_key: str | None, *, suffix: str,
) -> bytes:
    """GET a single file from ark and return its bytes."""
    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.get(f"{base}{suffix}", headers=_auth_headers(api_key))
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return resp.content


async def _ark_rename(
    base: str, api_key: str | None, *,
    suffix_template: str, src: str, dst: str,
) -> None:
    """Pass-through to ark's native rename. ark handles files and
    directories and refuses to silently overwrite (409 on dst conflict).
    Earlier revisions of this helper rolled a GET→PUT→DELETE composition
    here when ark didn't have rename — see git history if you need it."""
    src_suffix = suffix_template.format(path=src)
    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.post(
            f"{base}{src_suffix}",
            headers=_auth_headers(api_key),
            params={"op": "rename", "dest": dst},
        )
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)


def _safe_rel(path: str) -> str:
    """Strip leading slashes and refuse path-traversal escapes. ark
    enforces this server-side too but we double-check here so user input
    can't slip a `..` into our zip walk."""
    if "\\" in path or path.startswith("/"):
        raise HTTPException(status_code=400, detail="invalid path")
    parts = path.split("/")
    if any(p == ".." or p == "" or p == "." for p in parts if p):
        raise HTTPException(status_code=400, detail="invalid path")
    return path.strip("/")


async def _build_zip(
    base: str, api_key: str | None, *,
    suffix_template: str, root_path: str, archive_name: str,
) -> tuple[bytes, str]:
    """Recursively walk `root_path` via ark's listing endpoint, build a zip
    in memory, return (bytes, archive_filename). Capped at 500 MB to keep
    memory usage bounded; clients that need bigger should download files
    individually for now."""
    import io
    import zipfile

    MAX_BYTES = 500 * 1024 * 1024
    buf = io.BytesIO()
    total_bytes = 0
    with zipfile.ZipFile(buf, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:

        async def _walk(rel: str) -> None:
            nonlocal total_bytes
            suffix = suffix_template.format(path=rel)
            listing = await _ark_listing(base, api_key, suffix=suffix)
            for entry in listing.get("entries") or []:
                name = entry.get("name")
                if not isinstance(name, str) or name in (".", ".."):
                    continue
                child = f"{rel}/{name}" if rel else name
                if entry.get("is_dir"):
                    await _walk(child)
                else:
                    data = await _ark_file_bytes(
                        base, api_key, suffix=suffix_template.format(path=child),
                    )
                    total_bytes += len(data)
                    if total_bytes > MAX_BYTES:
                        raise HTTPException(
                            status_code=413,
                            detail="Directory too large to zip (>500 MB)",
                        )
                    # Strip the root path prefix so archive paths start
                    # at the user-selected directory rather than carrying
                    # absolute ark paths.
                    rel_in_zip = child
                    if root_path and rel_in_zip.startswith(root_path + "/"):
                        rel_in_zip = rel_in_zip[len(root_path) + 1:]
                    zf.writestr(rel_in_zip or name, data)

        await _walk(root_path)

    return buf.getvalue(), archive_name


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
    op: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key = await _ark_for_server(db, server)
    if op == "zip":
        safe = _safe_rel(path)
        archive_name = (safe.rsplit("/", 1)[-1] or "project") + ".zip"
        data, _ = await _build_zip(
            base, api_key,
            suffix_template=f"/projects/{project_id}/files/{{path}}",
            root_path=safe, archive_name=archive_name,
        )
        return Response(
            content=data,
            media_type="application/zip",
            headers={"Content-Disposition": f'attachment; filename="{archive_name}"'},
        )
    if op == "probe":
        return await _probe_via_ark(
            base, api_key, suffix=f"/projects/{project_id}/files/{path}",
        )
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


class RenameBody(BaseModel):
    to: str


@projects_router.post("/{project_id}/files/{path:path}")
async def project_file_post(
    project_id: str,
    path: str,
    op: str = Query(..., description="'mkdir' or 'rename'"),
    server: str | None = Query(None),
    body: RenameBody | None = None,
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key = await _ark_for_server(db, server)
    if op == "mkdir":
        return await _proxy_fs_mkdir(
            base, api_key, suffix=f"/projects/{project_id}/files/{path}",
        )
    if op == "rename":
        if body is None or not body.to.strip():
            raise HTTPException(status_code=400, detail="rename needs `to` in body")
        src = _safe_rel(path)
        dst = _safe_rel(body.to.strip())
        await _ark_rename(
            base, api_key,
            suffix_template=f"/projects/{project_id}/files/{{path}}",
            src=src, dst=dst,
        )
        return {"renamed": src, "to": dst}
    raise HTTPException(status_code=400, detail=f"unsupported op {op!r}")


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
    op: str | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key, agent = await _ark_for_agent(db, agent_id)
    name = _ark_agent_name(agent)
    if op == "zip":
        safe = _safe_rel(path)
        archive_name = (safe.rsplit("/", 1)[-1] or "workspace") + ".zip"
        data, _ = await _build_zip(
            base, api_key,
            suffix_template=f"/agents/{name}/files/{{path}}",
            root_path=safe, archive_name=archive_name,
        )
        return Response(
            content=data,
            media_type="application/zip",
            headers={"Content-Disposition": f'attachment; filename="{archive_name}"'},
        )
    if op == "probe":
        return await _probe_via_ark(
            base, api_key, suffix=f"/agents/{name}/files/{path}",
        )
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
async def workspace_file_post(
    agent_id: str,
    path: str,
    op: str = Query(..., description="'mkdir' or 'rename'"),
    body: RenameBody | None = None,
    db: AsyncSession = Depends(get_db),
):
    _sid, base, api_key, agent = await _ark_for_agent(db, agent_id)
    name = _ark_agent_name(agent)
    if op == "mkdir":
        return await _proxy_fs_mkdir(
            base, api_key, suffix=f"/agents/{name}/files/{path}",
        )
    if op == "rename":
        if body is None or not body.to.strip():
            raise HTTPException(status_code=400, detail="rename needs `to` in body")
        src = _safe_rel(path)
        dst = _safe_rel(body.to.strip())
        await _ark_rename(
            base, api_key,
            suffix_template=f"/agents/{name}/files/{{path}}",
            src=src, dst=dst,
        )
        return {"renamed": src, "to": dst}
    raise HTTPException(status_code=400, detail=f"unsupported op {op!r}")
