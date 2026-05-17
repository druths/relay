"""REST endpoints for platform-level settings (STT config, etc.)."""

from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.utils import mask_api_key
from app.db.database import get_db
from app.models.platform_setting import PlatformSetting

from app.api.auth import get_current_user

router = APIRouter(
    prefix="/v1/platform",
    tags=["platform"],
    dependencies=[Depends(get_current_user)],
)

# Defaults for platform settings
_DEFAULTS = {
    "stt_provider": "openai",
    "stt_silence_threshold_db": "-35",
    "stt_silence_timeout_ms": "500",
    "stt_min_duration_ms": "400",
    "stt_no_speech_threshold": "0.5",
    "stt_attack_debounce_ms": "300",
    "tts_default_provider": "openai",
    "voice_mode_instructions": (
        "You are in a live voice conversation. Keep all responses short and "
        "conversational — 1 to 3 sentences unless the user explicitly asks for "
        "more detail. Never use markdown, bullet points, headers, code blocks, "
        "numbered lists, or any text formatting. Speak naturally and directly, "
        "as if talking to someone in person."
    ),
}


class PlatformSettingsOut(BaseModel):
    stt_provider: str
    stt_api_key: str | None
    stt_silence_threshold_db: float
    stt_silence_timeout_ms: int
    stt_min_duration_ms: int
    stt_no_speech_threshold: float
    stt_attack_debounce_ms: int
    tts_default_provider: str
    tts_openai_api_key: str | None
    tts_elevenlabs_api_key: str | None
    voice_mode_instructions: str


class PlatformSettingsUpdate(BaseModel):
    stt_provider: str | None = None
    stt_api_key: str | None = None
    stt_silence_threshold_db: float | None = None
    stt_silence_timeout_ms: int | None = None
    stt_min_duration_ms: int | None = None
    stt_no_speech_threshold: float | None = None
    stt_attack_debounce_ms: int | None = None
    tts_default_provider: str | None = None
    tts_openai_api_key: str | None = None
    tts_elevenlabs_api_key: str | None = None
    voice_mode_instructions: str | None = None


async def _get_setting(db: AsyncSession, key: str) -> str:
    result = await db.execute(
        select(PlatformSetting).where(PlatformSetting.key == key)
    )
    row = result.scalar_one_or_none()
    return row.value if row else ""


async def _set_setting(db: AsyncSession, key: str, value: str) -> None:
    result = await db.execute(
        select(PlatformSetting).where(PlatformSetting.key == key)
    )
    row = result.scalar_one_or_none()
    if row:
        row.value = value
    else:
        db.add(PlatformSetting(key=key, value=value))


async def _build_response(db: AsyncSession) -> PlatformSettingsOut:
    stt_provider = await _get_setting(db, "stt_provider")
    stt_api_key = await _get_setting(db, "stt_api_key")
    silence_db = await _get_setting(db, "stt_silence_threshold_db")
    silence_ms = await _get_setting(db, "stt_silence_timeout_ms")
    min_dur = await _get_setting(db, "stt_min_duration_ms")
    no_speech = await _get_setting(db, "stt_no_speech_threshold")
    attack_ms = await _get_setting(db, "stt_attack_debounce_ms")
    tts_default = await _get_setting(db, "tts_default_provider")
    tts_openai_key = await _get_setting(db, "tts_openai_api_key")
    tts_el_key = await _get_setting(db, "tts_elevenlabs_api_key")
    voice_instructions = await _get_setting(db, "voice_mode_instructions")
    return PlatformSettingsOut(
        stt_provider=stt_provider or _DEFAULTS["stt_provider"],
        stt_api_key=mask_api_key(stt_api_key) if stt_api_key else None,
        stt_silence_threshold_db=float(silence_db or _DEFAULTS["stt_silence_threshold_db"]),
        stt_silence_timeout_ms=int(silence_ms or _DEFAULTS["stt_silence_timeout_ms"]),
        stt_min_duration_ms=int(min_dur or _DEFAULTS["stt_min_duration_ms"]),
        stt_no_speech_threshold=float(no_speech or _DEFAULTS["stt_no_speech_threshold"]),
        stt_attack_debounce_ms=int(attack_ms or _DEFAULTS["stt_attack_debounce_ms"]),
        tts_default_provider=tts_default or _DEFAULTS["tts_default_provider"],
        tts_openai_api_key=mask_api_key(tts_openai_key) if tts_openai_key else None,
        tts_elevenlabs_api_key=mask_api_key(tts_el_key) if tts_el_key else None,
        voice_mode_instructions=voice_instructions or _DEFAULTS["voice_mode_instructions"],
    )


@router.get("/settings", response_model=PlatformSettingsOut)
async def get_platform_settings(db: AsyncSession = Depends(get_db)):
    return await _build_response(db)


@router.patch("/settings", response_model=PlatformSettingsOut)
async def update_platform_settings(
    body: PlatformSettingsUpdate,
    db: AsyncSession = Depends(get_db),
):
    if body.stt_provider is not None:
        await _set_setting(db, "stt_provider", body.stt_provider)
    if body.stt_api_key is not None:
        await _set_setting(db, "stt_api_key", body.stt_api_key)
    if body.stt_silence_threshold_db is not None:
        await _set_setting(db, "stt_silence_threshold_db", str(body.stt_silence_threshold_db))
    if body.stt_silence_timeout_ms is not None:
        await _set_setting(db, "stt_silence_timeout_ms", str(body.stt_silence_timeout_ms))
    if body.stt_min_duration_ms is not None:
        await _set_setting(db, "stt_min_duration_ms", str(body.stt_min_duration_ms))
    if body.stt_no_speech_threshold is not None:
        await _set_setting(db, "stt_no_speech_threshold", str(body.stt_no_speech_threshold))
    if body.stt_attack_debounce_ms is not None:
        await _set_setting(db, "stt_attack_debounce_ms", str(body.stt_attack_debounce_ms))
    if body.tts_default_provider is not None:
        await _set_setting(db, "tts_default_provider", body.tts_default_provider)
    if body.tts_openai_api_key is not None:
        await _set_setting(db, "tts_openai_api_key", body.tts_openai_api_key)
    if body.tts_elevenlabs_api_key is not None:
        await _set_setting(db, "tts_elevenlabs_api_key", body.tts_elevenlabs_api_key)
    if body.voice_mode_instructions is not None:
        await _set_setting(db, "voice_mode_instructions", body.voice_mode_instructions)

    await db.commit()
    return await _build_response(db)


@router.get("/stt/status")
async def get_stt_status(db: AsyncSession = Depends(get_db)):
    from app.services.stt import get_stt_provider_from_db
    provider = await get_stt_provider_from_db(db)
    return {"available": provider is not None}


# ── Provider defaults (platform-wide fallback values) ────────────────


def _is_masked(value: str | None) -> bool:
    """Settings UI re-sends masked password values verbatim on save. Detect
    those so we don't overwrite the real stored key with the mask string."""
    return bool(value) and "•" in value


@router.get("/provider-defaults")
async def get_provider_defaults(db: AsyncSession = Depends(get_db)):
    """Return all platform-defaultable fields grouped by category and provider,
    with the current stored value (masked for password fields)."""
    from app.services.llm import list_provider_schemas as llm_schemas
    from app.services.tts import list_provider_schemas as tts_schemas
    from app.services.stt import list_provider_schemas as stt_schemas

    groups_input = [
        ("llm", "LLM", llm_schemas()),
        ("tts", "TTS", tts_schemas()),
        ("stt", "STT", stt_schemas()),
    ]

    # Collect every platform_key referenced, then look them all up in one go.
    all_keys: set[str] = set()
    for _, _, schemas in groups_input:
        for prov in schemas:
            for f in prov.get("fields", []):
                if f.get("platform_key"):
                    all_keys.add(f["platform_key"])

    res = await db.execute(
        select(PlatformSetting).where(PlatformSetting.key.in_(all_keys))
    )
    stored: dict[str, str] = {r.key: r.value for r in res.scalars().all() if r.value}

    out_groups = []
    for cat_id, cat_label, schemas in groups_input:
        providers_out = []
        for prov in schemas:
            fields_out = []
            for f in prov.get("fields", []):
                pk = f.get("platform_key")
                if not pk:
                    continue
                raw = stored.get(pk, "")
                value = mask_api_key(raw) if (raw and f.get("type") == "password") else raw
                fields_out.append({
                    "platform_key": pk,
                    "label": f.get("label", pk),
                    "type": f.get("type", "text"),
                    "placeholder": f.get("placeholder", ""),
                    "value": value or None,
                })
            if fields_out:
                providers_out.append({
                    "id": prov["id"],
                    "label": prov.get("label", prov["id"]),
                    "fields": fields_out,
                })
        if providers_out:
            out_groups.append({
                "category": cat_id,
                "label": cat_label,
                "providers": providers_out,
            })

    return {"groups": out_groups}


class ProviderDefaultsUpdate(BaseModel):
    """Flat dict of `{platform_key: value | null}`. Masked password values
    are ignored (no-op). Pass an empty string to clear a stored value."""
    values: dict[str, str | None]


@router.put("/provider-defaults")
async def update_provider_defaults(
    body: ProviderDefaultsUpdate,
    db: AsyncSession = Depends(get_db),
):
    """Persist updated platform defaults. Validates against the union of all
    declared platform_keys across LLM/TTS/STT schemas — unknown keys 400."""
    from app.services.llm import list_provider_schemas as llm_schemas
    from app.services.tts import list_provider_schemas as tts_schemas
    from app.services.stt import list_provider_schemas as stt_schemas

    known: set[str] = set()
    for schemas in (llm_schemas(), tts_schemas(), stt_schemas()):
        for prov in schemas:
            for f in prov.get("fields", []):
                if f.get("platform_key"):
                    known.add(f["platform_key"])

    unknown = [k for k in body.values if k not in known]
    if unknown:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail=f"Unknown platform keys: {unknown}")

    for key, value in body.values.items():
        if _is_masked(value):
            continue  # UI re-sent the mask; don't overwrite real value
        await _set_setting(db, key, value or "")
    await db.commit()
    return await get_provider_defaults(db)
