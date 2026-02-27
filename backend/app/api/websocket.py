"""WebSocket endpoint — the lobby connection."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
import uuid

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.services.conversation_manager import (
    get_session,
    get_session_messages,
    handle_lobby_message,
    handle_session_message_stream,
    pause_session,
)
from app.services.operator import operator_greeting
from app.services import agent_manager
from app.api.platform import _get_setting
from app.api.auth import verify_ws_token
from app.services.stt import get_stt_provider_from_db
from app.services.tts import get_tts_provider

logger = logging.getLogger(__name__)

router = APIRouter()

# Sentence-splitting regex: split after .!? followed by whitespace, or on newlines
_SENTENCE_RE = re.compile(r'(?<=[.!?])\s+|\n+')
_MAX_CHUNK_WORDS = 20


@router.websocket("/v1/lobby")
async def lobby_ws(websocket: WebSocket, token: str = Query(...)):
    # Verify JWT before accepting the connection
    try:
        verify_ws_token(token)
    except ValueError:
        await websocket.close(code=4001, reason="Authentication failed")
        return

    await websocket.accept()

    user_id = "default"
    active_session_id: uuid.UUID | None = None
    lobby_history: list[dict] = []  # In-memory conversation history for the LLM Operator

    try:
        async with websocket.app.state.db_session() as db:
            # Operator greeting (ephemeral — not persisted)
            greeting = operator_greeting()
            lobby_history.append({"role": "assistant", "content": greeting})

            await websocket.send_json({
                "type": "state_update",
                "payload": {
                    "active_speaker": "operator",
                    "status": "ready",
                    "session_id": None,
                },
            })
            await websocket.send_json({
                "type": "text",
                "payload": {"speaker": "operator", "text": greeting},
            })
            await _tts_for_text(websocket, db, greeting, "operator")

            while True:
                raw = await websocket.receive_text()
                data = json.loads(raw)
                msg_type = data.get("type")

                if msg_type == "text_input":
                    text = data["payload"]["text"]
                    active_session_id = await _handle_text(
                        websocket, db, user_id, text, active_session_id, lobby_history
                    )

                elif msg_type == "audio_input":
                    audio_data_b64 = data["payload"]["data"]
                    audio_format = data["payload"].get("format", "webm")

                    stt = await get_stt_provider_from_db(db)
                    if not stt:
                        await websocket.send_json({
                            "type": "error",
                            "payload": {"message": "No STT provider available"},
                        })
                        continue

                    try:
                        audio_bytes = base64.b64decode(audio_data_b64)
                        threshold_str = await _get_setting(db, "stt_no_speech_threshold")
                        no_speech_threshold = float(threshold_str) if threshold_str else 0.5
                        text = await stt.transcribe(audio_bytes, audio_format, no_speech_threshold=no_speech_threshold)
                    except Exception as exc:
                        logger.warning("STT transcription failed: %s", exc)
                        await websocket.send_json({
                            "type": "error",
                            "payload": {"message": f"Transcription failed: {exc}"},
                        })
                        continue

                    if not text.strip():
                        continue

                    # Send transcription back so the UI shows what was heard
                    await websocket.send_json({
                        "type": "transcription",
                        "payload": {"text": text},
                    })

                    active_session_id = await _handle_text(
                        websocket, db, user_id, text, active_session_id, lobby_history
                    )

                elif msg_type == "leave_session":
                    if active_session_id:
                        await pause_session(db, active_session_id)
                        active_session_id = None
                        await websocket.send_json({
                            "type": "session_left",
                            "payload": {"session_id": None},
                        })
                        await websocket.send_json({
                            "type": "state_update",
                            "payload": {
                                "active_speaker": "operator",
                                "status": "ready",
                                "session_id": None,
                            },
                        })
                        reply = "You're back with the Operator. What can I do for you?"
                        lobby_history.append({"role": "assistant", "content": reply})
                        await websocket.send_json({
                            "type": "text",
                            "payload": {"speaker": "operator", "text": reply},
                        })
                        await _tts_for_text(websocket, db, reply, "operator")

                elif msg_type == "resume_session":
                    target_sid = uuid.UUID(data["payload"]["session_id"])
                    active_session_id = await _do_resume(
                        websocket, db, user_id, target_sid, active_session_id
                    )

    except WebSocketDisconnect:
        if active_session_id:
            try:
                async with websocket.app.state.db_session() as db:
                    await pause_session(db, active_session_id)
            except Exception:
                pass
    except Exception as e:
        try:
            await websocket.send_json(
                {"type": "error", "payload": {"message": str(e)}}
            )
        except Exception:
            pass


async def _handle_text(
    websocket: WebSocket,
    db,
    user_id: str,
    text: str,
    active_session_id: uuid.UUID | None,
    lobby_history: list[dict],
) -> uuid.UUID | None:
    """Process user text (from typing or STT). Returns updated active_session_id."""
    # Processing indicator
    await websocket.send_json({
        "type": "state_update",
        "payload": {
            "active_speaker": "system",
            "status": "processing",
            "session_id": str(active_session_id) if active_session_id else None,
        },
    })

    if active_session_id is None:
        # Track user message in lobby history
        lobby_history.append({"role": "user", "content": text})
        events = await handle_lobby_message(db, user_id, text, lobby_history)
        return await _dispatch_events(
            websocket, db, user_id, events, active_session_id, lobby_history
        )

    # Stream session messages with TTS
    ws_lock = asyncio.Lock()
    tts_provider = None
    tts_agent = None
    tts_buffer = ""
    tts_seq = 0
    tts_tasks: list[asyncio.Task] = []

    async for event in handle_session_message_stream(db, active_session_id, text):
        etype = event["type"]

        if etype == "session_left":
            active_session_id = None
            await websocket.send_json(event)
        elif etype == "lobby_redirect":
            redirect_text = event["payload"]["text"]
            lobby_history.append({"role": "user", "content": redirect_text})
            redirect_events = await handle_lobby_message(
                db, user_id, redirect_text, lobby_history
            )
            active_session_id = await _dispatch_events(
                websocket, db, user_id, redirect_events, active_session_id, lobby_history
            )
        elif etype == "text":
            speaker = event["payload"].get("speaker", "")
            if active_session_id is None and speaker == "operator":
                lobby_history.append({"role": "assistant", "content": event["payload"]["text"]})
            await websocket.send_json(event)
            await _tts_for_text(websocket, db, event["payload"]["text"], speaker)
        else:
            await websocket.send_json(event)

        # ── TTS orchestration ──
        if etype == "text_start":
            session = await get_session(db, active_session_id) if active_session_id else None
            if session:
                tts_agent = await agent_manager.get_agent_by_id(db, session.agent_id)
                if tts_agent:
                    logger.info(
                        "Stream TTS resolve: agent=%s, tts_provider=%s, voice_id=%s, has_agent_key=%s",
                        tts_agent.name, tts_agent.tts_provider, tts_agent.voice_id, bool(tts_agent.tts_api_key),
                    )
                    tts_key = tts_agent.tts_api_key
                    if not tts_key:
                        setting_key = f"tts_{tts_agent.tts_provider}_api_key"
                        tts_key = await _get_setting(db, setting_key) or None
                        logger.info("Stream TTS key fallback: setting=%s, found=%s", setting_key, bool(tts_key))
                    tts_provider = get_tts_provider(tts_agent.tts_provider, tts_key)
            if tts_provider:
                tts_buffer = ""
                tts_seq = 0
                tts_tasks = []
                tts_semaphore = asyncio.Semaphore(2)
                async with ws_lock:
                    await websocket.send_json({
                        "type": "audio_start",
                        "payload": {"speaker": event["payload"]["speaker"]},
                    })

        elif etype == "text_delta" and tts_provider and tts_agent:
            tts_buffer += event["payload"]["delta"]
            sentences, tts_buffer = _extract_sentences(tts_buffer)
            for sentence in sentences:
                seq = tts_seq
                tts_seq += 1
                task = asyncio.create_task(
                    _synth_and_send(websocket, ws_lock, tts_provider, tts_agent, sentence, seq, tts_semaphore)
                )
                tts_tasks.append(task)

        elif etype == "text_done" and tts_provider and tts_agent:
            if tts_buffer.strip():
                seq = tts_seq
                tts_seq += 1
                task = asyncio.create_task(
                    _synth_and_send(websocket, ws_lock, tts_provider, tts_agent, tts_buffer, seq, tts_semaphore)
                )
                tts_tasks.append(task)
            if tts_tasks:
                await asyncio.gather(*tts_tasks)
            async with ws_lock:
                await websocket.send_json({
                    "type": "audio_done",
                    "payload": {"speaker": event["payload"]["speaker"]},
                })
            tts_provider = None
            tts_agent = None

    return active_session_id


def _extract_sentences(buffer: str) -> tuple[list[str], str]:
    """Split buffer on sentence/newline boundaries with a word-count fallback.

    Returns (complete_chunks, remaining_buffer).
    """
    parts = _SENTENCE_RE.split(buffer)
    if len(parts) <= 1:
        # No sentence/newline boundary — fall back to word count
        words = buffer.split()
        if len(words) > _MAX_CHUNK_WORDS:
            cut = " ".join(words[:_MAX_CHUNK_WORDS])
            remaining = " ".join(words[_MAX_CHUNK_WORDS:])
            return [cut], remaining
        return [], buffer
    sentences = parts[:-1]
    remaining = parts[-1]
    chunks: list[str] = []
    for s in sentences:
        s = s.strip()
        if not s:
            continue
        chunks.extend(_split_long(s))
    return chunks, remaining


def _split_long(text: str) -> list[str]:
    """Break text exceeding _MAX_CHUNK_WORDS into sub-chunks."""
    words = text.split()
    if len(words) <= _MAX_CHUNK_WORDS:
        return [text]
    return [
        " ".join(words[i : i + _MAX_CHUNK_WORDS])
        for i in range(0, len(words), _MAX_CHUNK_WORDS)
    ]


async def _synth_and_send(
    websocket: WebSocket,
    lock: asyncio.Lock,
    provider,
    agent,
    text: str,
    seq: int,
    semaphore: asyncio.Semaphore | None = None,
) -> None:
    """Synthesize a sentence and send the audio chunk over WebSocket."""
    try:
        if semaphore:
            await semaphore.acquire()
        try:
            audio_bytes = await provider.synthesize(text, agent.voice_id, agent.voice_settings)
        finally:
            if semaphore:
                semaphore.release()
        data = base64.b64encode(audio_bytes).decode()
        async with lock:
            await websocket.send_json({
                "type": "audio_chunk",
                "payload": {
                    "speaker": agent.name,
                    "data": data,
                    "format": "mp3",
                    "sequence": seq,
                },
            })
    except Exception as exc:
        logger.warning("TTS synthesis failed for seq %d (%d chars): %s", seq, len(text), exc, exc_info=True)
        # Send an empty chunk so the frontend doesn't block on this sequence
        try:
            async with lock:
                await websocket.send_json({
                    "type": "audio_chunk",
                    "payload": {
                        "speaker": agent.name,
                        "data": "",
                        "format": "mp3",
                        "sequence": seq,
                    },
                })
        except Exception:
            pass


async def _tts_for_text(
    websocket: WebSocket,
    db,
    text: str,
    speaker_name: str,
) -> None:
    """Synthesize TTS for a complete (non-streaming) text message."""
    agent = await agent_manager.get_agent_by_name(db, speaker_name)
    if not agent:
        logger.debug("TTS: no agent found for speaker=%s", speaker_name)
        return
    logger.info(
        "TTS resolve: speaker=%s, agent=%s, tts_provider=%s, voice_id=%s, has_agent_key=%s",
        speaker_name, agent.name, agent.tts_provider, agent.voice_id, bool(agent.tts_api_key),
    )
    api_key = agent.tts_api_key
    if not api_key:
        setting_key = f"tts_{agent.tts_provider}_api_key"
        api_key = await _get_setting(db, setting_key) or None
        logger.info(
            "TTS key fallback: setting=%s, found=%s",
            setting_key, bool(api_key),
        )
    provider = get_tts_provider(agent.tts_provider, api_key)
    if not provider:
        logger.warning(
            "TTS: get_tts_provider returned None for provider=%s, has_key=%s",
            agent.tts_provider, bool(api_key),
        )
        return

    try:
        await websocket.send_json({
            "type": "audio_start",
            "payload": {"speaker": speaker_name},
        })

        audio_bytes = await provider.synthesize(text, agent.voice_id, agent.voice_settings)
        logger.info("TTS: synthesized %d bytes for speaker=%s", len(audio_bytes), speaker_name)
        data = base64.b64encode(audio_bytes).decode()
        await websocket.send_json({
            "type": "audio_chunk",
            "payload": {
                "speaker": speaker_name,
                "data": data,
                "format": "mp3",
                "sequence": 0,
            },
        })

        await websocket.send_json({
            "type": "audio_done",
            "payload": {"speaker": speaker_name},
        })
    except Exception as exc:
        logger.warning("TTS for text failed (speaker=%s): %s", speaker_name, exc)


async def _do_resume(
    websocket: WebSocket,
    db,
    user_id: str,
    target_sid: uuid.UUID,
    active_session_id: uuid.UUID | None,
) -> uuid.UUID | None:
    """Resume a specific session. Returns the new active_session_id."""
    session = await get_session(db, target_sid)
    if not session or session.user_id != user_id:
        return active_session_id

    if active_session_id:
        await pause_session(db, active_session_id)

    session.status = "active"
    await db.commit()

    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    await websocket.send_json({
        "type": "session_entered",
        "payload": {
            "session_id": str(session.session_id),
            "agent_name": agent.name if agent else "Unknown",
        },
    })
    messages = await get_session_messages(db, session.session_id)
    await websocket.send_json({
        "type": "session_history",
        "payload": {"messages": messages},
    })
    return session.session_id


async def _dispatch_events(
    websocket: WebSocket,
    db,
    user_id: str,
    events: list[dict],
    active_session_id: uuid.UUID | None,
    lobby_history: list[dict],
) -> uuid.UUID | None:
    """Send events to client, intercepting internal routing events."""
    for event in events:
        etype = event["type"]

        if etype == "session_entered":
            active_session_id = uuid.UUID(event["payload"]["session_id"])
            await websocket.send_json(event)

        elif etype == "session_left":
            active_session_id = None
            await websocket.send_json(event)

        elif etype == "lobby_redirect":
            # Agent switching: pause happened, re-route through lobby
            redirect_text = event["payload"]["text"]
            lobby_history.append({"role": "user", "content": redirect_text})
            redirect_events = await handle_lobby_message(
                db, user_id, redirect_text, lobby_history
            )
            active_session_id = await _dispatch_events(
                websocket, db, user_id, redirect_events, active_session_id, lobby_history
            )

        elif etype == "resume_via_lobby":
            # LLM Operator decided to resume a session
            sid_str = event["payload"]["session_id"]
            # Handle partial session IDs from the LLM
            full_sid = await _resolve_session_id(db, user_id, sid_str)
            if full_sid:
                active_session_id = await _do_resume(
                    websocket, db, user_id, full_sid, active_session_id
                )

        elif etype == "text":
            # Track operator text responses in lobby history
            speaker = event["payload"].get("speaker", "")
            if active_session_id is None and speaker == "operator":
                lobby_history.append({"role": "assistant", "content": event["payload"]["text"]})
            await websocket.send_json(event)
            await _tts_for_text(websocket, db, event["payload"]["text"], speaker)

        else:
            await websocket.send_json(event)

    return active_session_id


async def _resolve_session_id(db, user_id: str, sid_str: str) -> uuid.UUID | None:
    """Resolve a full or partial session ID to a UUID."""
    # Strip trailing dots/ellipsis the LLM may include
    sid_str = sid_str.rstrip(".").rstrip("\u2026").strip()

    # Try parsing as full UUID first
    try:
        return uuid.UUID(sid_str)
    except ValueError:
        pass

    # Try matching as a prefix against the user's sessions
    from app.services.conversation_manager import list_sessions
    sessions = await list_sessions(db, user_id)
    for s in sessions:
        if s["session_id"].startswith(sid_str):
            return uuid.UUID(s["session_id"])
    return None
