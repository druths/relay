"""REST endpoints for file upload and download."""

from __future__ import annotations

import os
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.auth import get_current_user
from app.db.database import get_db
from app.models.file import File

router = APIRouter(
    prefix="/v1/files",
    tags=["files"],
    dependencies=[Depends(get_current_user)],
)

UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/app/uploads"))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)


class FileOut(BaseModel):
    file_id: str
    filename: str
    mime_type: str
    size_bytes: int
    url: str
    created_at: str


@router.post("", response_model=FileOut, status_code=201)
async def upload_file(
    file: UploadFile,
    session_id: str | None = None,
    user_id: str = "default",
    db: AsyncSession = Depends(get_db),
):
    """Upload a file. Returns metadata including the download URL."""
    file_id = uuid.uuid4()
    file_dir = UPLOAD_DIR / str(file_id)
    file_dir.mkdir(parents=True, exist_ok=True)

    # Sanitize filename
    original_name = file.filename or "upload"
    safe_name = original_name.replace("/", "_").replace("\\", "_")
    file_path = file_dir / safe_name

    # Write file to disk
    content = await file.read()
    file_path.write_bytes(content)

    # Store metadata in DB
    db_file = File(
        file_id=file_id,
        session_id=uuid.UUID(session_id) if session_id else None,
        user_id=user_id,
        filename=safe_name,
        mime_type=file.content_type or "application/octet-stream",
        size_bytes=len(content),
        storage_path=str(file_path),
    )
    db.add(db_file)
    await db.commit()

    return FileOut(
        file_id=str(file_id),
        filename=safe_name,
        mime_type=db_file.mime_type,
        size_bytes=db_file.size_bytes,
        url=f"/v1/files/{file_id}/{safe_name}",
        created_at=db_file.created_at.isoformat(),
    )


@router.get("/{file_id}/{filename}")
async def download_file(
    file_id: uuid.UUID,
    filename: str,
    db: AsyncSession = Depends(get_db),
):
    """Download a file by ID. The filename in the URL is for convenience/SEO."""
    from sqlalchemy import select
    result = await db.execute(
        select(File).where(File.file_id == file_id)
    )
    db_file = result.scalar_one_or_none()
    if not db_file:
        raise HTTPException(status_code=404, detail="File not found")

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
    from sqlalchemy import select
    result = await db.execute(
        select(File).where(File.file_id == file_id)
    )
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
