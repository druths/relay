"""REST endpoints for file upload and download.

Upload behavior depends on the owning session's agent:
- For sessions backed by an ark agent, files are proxied through to ark's
  POST /agents/<name>/sessions/<sid>/uploads endpoint and the File row's
  storage_path is recorded with an ``ark:<agent>:<relative-path>`` scheme.
- For everything else (or no session), bytes are written to the local
  /app/uploads volume and storage_path is the absolute disk path.

Download mirrors that: ``ark:`` paths stream from ark; local paths use a
plain FileResponse.
"""

from __future__ import annotations

import logging
import os
import uuid
from pathlib import Path

import httpx
from fastapi import APIRouter, Depends, HTTPException, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.db.database import get_db
from app.db.redis import get_provider_state
from app.models.agent import Agent
from app.models.file import File
from app.models.session import Session
from app.services.agent_manager import ArkFileRef, get_ark_agent, resolve_llm_config

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/v1/files",
    tags=["files"],
    dependencies=[Depends(get_current_user)],
)

UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/app/uploads"))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

ARK_SCHEME = "ark:"


class FileOut(BaseModel):
    file_id: str
    filename: str
    mime_type: str
    size_bytes: int
    url: str
    created_at: str


# ── Helpers ─────────────────────────────────────────────────────────


async def _ark_target_for_session(
    db: AsyncSession, session_id: uuid.UUID,
) -> tuple[Agent, str] | None:
    """If the session is backed by an ark agent and has an ark session_id
    in provider_state, return (agent, ark_session_id). Otherwise None."""
    sess_result = await db.execute(
        select(Session).where(Session.session_id == session_id)
    )
    sess = sess_result.scalar_one_or_none()
    if sess is None:
        return None
    agent_result = await db.execute(
        select(Agent).where(Agent.agent_id == sess.agent_id)
    )
    agent = agent_result.scalar_one_or_none()
    if agent is None or agent.llm_provider != "ark":
        return None
    ark_sid = await get_provider_state(str(session_id), "ark")
    if not ark_sid:
        return None
    return agent, ark_sid


def _ark_agent_name(agent: Agent) -> str:
    """Ark agent name lives in agent.llm_model (optionally with ark: prefix)."""
    model = agent.llm_model or ""
    return model[len("ark:"):] if model.startswith("ark:") else model


# ── Routes ──────────────────────────────────────────────────────────


@router.post("", response_model=FileOut, status_code=201)
async def upload_file(
    file: UploadFile,
    session_id: str | None = None,
    user_id: str = "default",
    db: AsyncSession = Depends(get_db),
):
    """Upload a file. If the owning session is ark-backed, the bytes are
    forwarded to ark; otherwise stored locally. Returns metadata with a
    Relay-internal download URL either way."""
    original_name = file.filename or "upload"
    safe_name = original_name.replace("/", "_").replace("\\", "_")
    content = await file.read()
    mime_type = file.content_type or "application/octet-stream"

    file_id = uuid.uuid4()
    storage_path: str

    # Decide: ark proxy vs local.
    ark_target: tuple[Agent, str] | None = None
    if session_id:
        try:
            ark_target = await _ark_target_for_session(db, uuid.UUID(session_id))
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid session_id")

    if ark_target is not None:
        agent, ark_sid = ark_target
        name = _ark_agent_name(agent)
        base_url, api_key = await resolve_llm_config(agent)
        base = (base_url or "").rstrip("/")
        if not base:
            raise HTTPException(status_code=500, detail="Ark agent missing base_url")
        url = f"{base}/agents/{name}/sessions/{ark_sid}/uploads"
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        try:
            async with httpx.AsyncClient(timeout=120) as client:
                resp = await client.post(
                    url, headers=headers,
                    files={"file": (safe_name, content, mime_type)},
                )
                resp.raise_for_status()
                data = resp.json()
        except httpx.HTTPStatusError as exc:
            logger.warning("Ark upload failed (%s): %s", exc.response.status_code, exc.response.text[:200])
            raise HTTPException(status_code=exc.response.status_code, detail=f"Ark upload failed: {exc.response.text[:200]}")
        except Exception as exc:
            logger.exception("Ark upload request failed")
            raise HTTPException(status_code=502, detail=f"Ark upload request failed: {exc}")
        # Ark returns {path, size, original_name}. The `path` is workspace-relative.
        ark_path = data.get("path")
        if not ark_path:
            raise HTTPException(status_code=502, detail="Ark upload response missing path")
        storage_path = f"{ARK_SCHEME}{name}:{ark_path}"
        size_bytes = int(data.get("size") or len(content))
    else:
        # Local on-disk storage.
        file_dir = UPLOAD_DIR / str(file_id)
        file_dir.mkdir(parents=True, exist_ok=True)
        disk_path = file_dir / safe_name
        disk_path.write_bytes(content)
        storage_path = str(disk_path)
        size_bytes = len(content)

    db_file = File(
        file_id=file_id,
        session_id=uuid.UUID(session_id) if session_id else None,
        user_id=user_id,
        filename=safe_name,
        mime_type=mime_type,
        size_bytes=size_bytes,
        storage_path=storage_path,
    )
    db.add(db_file)
    await db.commit()

    # Invalidate cached history so the new attachment shows on resume.
    if session_id:
        from app.db.redis import invalidate_session_cache
        await invalidate_session_cache(session_id)

    return FileOut(
        file_id=str(file_id),
        filename=safe_name,
        mime_type=mime_type,
        size_bytes=size_bytes,
        url=f"/v1/files/{file_id}/{safe_name}",
        created_at=db_file.created_at.isoformat(),
    )


async def _resolve_ark_agent(db: AsyncSession, agent_name: str) -> Agent:
    agent = await get_ark_agent(db, agent_name)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"Ark agent {agent_name} not found")
    return agent


async def _stream_from_ark(
    db: AsyncSession, ref: ArkFileRef, filename: str,
) -> StreamingResponse:
    """Stream an ark workspace or project file through to the client."""
    agent = await _resolve_ark_agent(db, ref.agent_name)
    base_url, api_key = await resolve_llm_config(agent)
    base = (base_url or "").rstrip("/")
    if not base:
        raise HTTPException(status_code=500, detail="Ark agent missing base_url")
    if ref.project_id:
        url = f"{base}/projects/{ref.project_id}/files/{ref.path}"
    else:
        url = f"{base}/agents/{_ark_agent_name(agent)}/files/{ref.path}"

    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    client = httpx.AsyncClient(timeout=60)
    try:
        req = client.build_request("GET", url, headers=headers)
        resp = await client.send(req, stream=True)
        resp.raise_for_status()
    except httpx.HTTPStatusError as exc:
        await resp.aclose()
        await client.aclose()
        raise HTTPException(status_code=exc.response.status_code, detail="Ark download failed")
    except Exception as exc:
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Ark download failed: {exc}")

    async def _stream():
        try:
            async for chunk in resp.aiter_bytes():
                yield chunk
        finally:
            await resp.aclose()
            await client.aclose()

    return StreamingResponse(
        _stream(),
        media_type=resp.headers.get("content-type", "application/octet-stream"),
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/ark/{agent_name}/{ark_path:path}")
async def download_ark_file_passthrough(
    agent_name: str,
    ark_path: str,
    db: AsyncSession = Depends(get_db),
):
    """Stream an agent workspace file by name + path. Registered before the
    file-id route so the `ark` prefix is matched literally. Older iOS builds
    still build these URLs for shared files."""
    ref = ArkFileRef(agent_name=agent_name, path=ark_path)
    return await _stream_from_ark(db, ref, ark_path.split("/")[-1] or "file")


@router.get("/{file_id}/{filename}")
async def download_file(
    file_id: uuid.UUID,
    filename: str,
    db: AsyncSession = Depends(get_db),
):
    """Download a file by ID. Falls through to ark for ark-stored files."""
    result = await db.execute(select(File).where(File.file_id == file_id))
    db_file = result.scalar_one_or_none()
    if not db_file:
        raise HTTPException(status_code=404, detail="File not found")

    ref = ArkFileRef.parse(db_file.storage_path)
    if ref is not None:
        return await _stream_from_ark(db, ref, db_file.filename)

    file_path = Path(db_file.storage_path)
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="File data not found on disk")

    return FileResponse(
        path=str(file_path),
        filename=db_file.filename,
        media_type=db_file.mime_type,
    )


@router.get("/{file_id}/meta", response_model=FileOut)
async def get_file_metadata(
    file_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
):
    """Get file metadata without downloading."""
    result = await db.execute(select(File).where(File.file_id == file_id))
    db_file = result.scalar_one_or_none()
    if not db_file:
        raise HTTPException(status_code=404, detail="File not found")

    return FileOut(
        file_id=str(db_file.file_id),
        filename=db_file.filename,
        mime_type=db_file.mime_type,
        size_bytes=db_file.size_bytes,
        url=f"/v1/files/{db_file.file_id}/{db_file.filename}",
        created_at=db_file.created_at.isoformat(),
    )
