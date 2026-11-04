"""WebSocket endpoint — the lobby connection."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
import uuid
from collections import deque

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.services.conversation_manager import (
    get_session,
    get_session_labels,
    get_session_messages,
    handle_lobby_message,
    handle_session_message_stream,
    mark_session_read,
    mark_session_unread,
    pause_session,
    rename_session,
    set_session_labels,
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

# Pre-compiled regex constants for TTS text normalization
_TTS_FENCED_CODE_RE = re.compile(r'```[\s\S]*?```')
_TTS_HEADING_RE = re.compile(r'^#{1,6}\s+', re.MULTILINE)
_TTS_LIST_RE = re.compile(r'^\s*(?:[-•*]|\d+\.)\s+', re.MULTILINE)
_TTS_BOLD_RE = re.compile(r'\*\*([^*]+)\*\*')
_TTS_ITALIC_RE = re.compile(r'(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!\w)_([^_\n]+)_(?!\w)')
_TTS_INLINE_CODE_RE = re.compile(r'`([^`]+)`')
_TTS_URL_RE = re.compile(r'https?://\S+')
_TTS_ELLIPSIS_RE = re.compile(r'\.{2,}|\u2026')
_TTS_EMOJI_RE = re.compile(
    r'[\U0001F300-\U0001F9FF\U00002600-\U000027FF\U00002300-\U000023FF\U0000FE00-\U0000FEFF]'
)
_TTS_TRAILING_PUNCT_RE = re.compile(r'[.,;:]+$')


# ── Connection registry for multi-client broadcast ─────────────────────
_user_connections: dict[str, set[WebSocket]] = {}


def _register_connection(user_id: str, ws: WebSocket) -> None:
    _user_connections.setdefault(user_id, set()).add(ws)


def _unregister_connection(user_id: str, ws: WebSocket) -> None:
    if user_id in _user_connections:
        _user_connections[user_id].discard(ws)
        if not _user_connections[user_id]:
            del _user_connections[user_id]


async def _broadcast_to_user(user_id: str, event: dict) -> None:
    """Send an event to all connected WebSocket clients for a user."""
    for ws in list(_user_connections.get(user_id, [])):
        try:
            await ws.send_json(event)
        except Exception:
            pass


async def _broadcast_to_all(event: dict) -> None:
    """Send an event to every connected client across every user. Used for
    ark-server-global events (project_file_changed, workspace_file_changed)
    that have no per-session targeting. Clients filter by project_id /
    agent_name themselves."""
    for sockets in list(_user_connections.values()):
        for ws in list(sockets):
            try:
                await ws.send_json(event)
            except Exception:
                pass


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
    _register_connection(user_id, websocket)
    active_session_id: uuid.UUID | None = None
    lobby_history: list[dict] = []  # In-memory conversation history for the LLM Operator
    is_live_mode = False
    # Client can play raw PCM (`audio_chunk` format "pcm16"), so streaming
    # TTS providers may be used. Declared with set_live_mode.
    pcm_stream_ok = False
    # Signal to detach in-flight task (let it finish in background)
    detach_event = asyncio.Event()
    voice_mode_instructions: str | None = None

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
            # No TTS at connect time — the client hasn't declared voice
            # mode yet (they'd need to send set_live_mode first), and we
            # don't want to burn a synth API call for audio nobody will
            # play. Live mode later re-invokes any needed prompts.

            # Concurrent message loop: races incoming WS messages against active
            # processing so that "interrupt" messages can cancel in-flight LLM/TTS turns.
            active_task: asyncio.Task | None = None
            # In-flight transcriptions, oldest first. STT runs off the loop
            # so a slow provider can't block interrupts or leave_session;
            # results are consumed in arrival order so utterances never
            # reach the agent out of sequence.
            stt_tasks: deque[asyncio.Task] = deque()
            recv_task: asyncio.Task = asyncio.create_task(websocket.receive_text())

            try:
                while True:
                    watch = {recv_task}
                    if active_task and not active_task.done():
                        watch.add(active_task)
                    if stt_tasks:
                        watch.add(stt_tasks[0])

                    done, _ = await asyncio.wait(watch, return_when=asyncio.FIRST_COMPLETED)

                    # Processing task finished — capture updated active_session_id
                    if active_task in done:
                        try:
                            active_session_id = active_task.result()
                        except asyncio.CancelledError:
                            pass
                        except Exception as e:
                            logger.error("Processing task failed: %s", e)
                        active_task = None

                    while stt_tasks and stt_tasks[0].done():
                        finished = stt_tasks.popleft()
                        if finished.cancelled():
                            continue
                        text, tz = finished.result()
                        if not text:
                            continue

                        # Send transcription back so the UI shows what was heard
                        await websocket.send_json({
                            "type": "transcription",
                            "payload": {"text": text},
                        })

                        await _cancel_active_task(active_task)
                        detach_event = asyncio.Event()
                        active_task = asyncio.create_task(
                            _handle_text_own_session(
                                websocket, user_id, text, active_session_id, lobby_history,
                                voice_mode_instructions if is_live_mode else None,
                                detach_event=detach_event,
                                is_live_mode=is_live_mode,
                                stream_audio=pcm_stream_ok,
                                timezone=tz)
                        )

                    # No new message — loop back to wait again
                    if recv_task not in done:
                        continue

                    # New message arrived; re-raise any transport errors (e.g. WebSocketDisconnect)
                    raw = recv_task.result()
                    recv_task = asyncio.create_task(websocket.receive_text())
                    data = json.loads(raw)
                    msg_type = data.get("type")
                    # Turns write through their own sessions; drop anything
                    # this one cached so reads (e.g. the ark session id for
                    # stop_session) see those writes.
                    db.expire_all()

                    if msg_type == "interrupt":
                        logger.info("[WS] interrupt received — cancelling active task")
                        await _cancel_active_task(active_task)
                        active_task = None
                        await websocket.send_json({
                            "type": "state_update",
                            "payload": {
                                "active_speaker": "user",
                                "status": "ready",
                                "session_id": str(active_session_id) if active_session_id else None,
                            },
                        })

                    elif msg_type == "set_live_mode":
                        is_live_mode = data["payload"].get("enabled", False)
                        pcm_stream_ok = is_live_mode and bool(data["payload"].get("pcm_stream"))
                        if is_live_mode:
                            raw = await _get_setting(db, "voice_mode_instructions")
                            voice_mode_instructions = raw or None
                        else:
                            voice_mode_instructions = None
                        logger.info("[WS] set_live_mode=%s", is_live_mode)

                    elif msg_type == "text_input":
                        text = data["payload"]["text"]
                        tz = data["payload"].get("timezone")

                        await _cancel_active_task(active_task)
                        detach_event = asyncio.Event()  # Fresh event for each task
                        active_task = asyncio.create_task(
                            _handle_text_own_session(
                                websocket, user_id, text, active_session_id, lobby_history,
                                voice_mode_instructions if is_live_mode else None,
                                detach_event=detach_event,
                                is_live_mode=is_live_mode,
                                stream_audio=pcm_stream_ok,
                                timezone=tz)
                        )

                    elif msg_type == "audio_input":
                        audio_data_b64 = data["payload"]["data"]
                        audio_format = data["payload"].get("format", "webm")
                        tz = data["payload"].get("timezone")

                        stt = await get_stt_provider_from_db(db)
                        if not stt:
                            await websocket.send_json({
                                "type": "error",
                                "payload": {"message": "No STT provider available"},
                            })
                            continue

                        threshold_str = await _get_setting(db, "stt_no_speech_threshold")
                        no_speech_threshold = float(threshold_str) if threshold_str else 0.5
                        stt_tasks.append(asyncio.create_task(
                            _transcribe(websocket, stt, audio_data_b64, audio_format,
                                        no_speech_threshold, tz)
                        ))

                    elif msg_type == "leave_session":
                        _cancel_stt_tasks(stt_tasks)
                        task_still_running = active_task is not None and not active_task.done()
                        if task_still_running:
                            # Signal task to stop sending to WS but finish in background
                            detach_event.set()
                            active_task = None
                            detach_event = asyncio.Event()
                        else:
                            active_task = None

                        if active_session_id:
                            left_session_id = active_session_id
                            active_session_id = None

                            # Check if session should be deleted (no user messages)
                            from app.services.conversation_manager import has_user_messages
                            has_msgs = await has_user_messages(db, left_session_id)
                            if not has_msgs:
                                from app.services.conversation_manager import delete_session
                                await delete_session(db, left_session_id)
                                await websocket.send_json({
                                    "type": "session_deleted",
                                    "payload": {"session_id": str(left_session_id)},
                                })
                            else:
                                session = await get_session(db, left_session_id)
                                if session:
                                    # "processing" if agent is still generating in background, "paused" otherwise
                                    session.status = "processing" if task_still_running else "paused"
                                    await db.commit()
                                await websocket.send_json({
                                    "type": "session_left",
                                    "payload": {
                                        "session_id": None,
                                        "reason": "client_leave_session",
                                        "detail": {
                                            "previous_session_id": str(left_session_id),
                                        },
                                    },
                                })

                            await websocket.send_json({
                                "type": "state_update",
                                "payload": {
                                    "active_speaker": "operator",
                                    "status": "ready",
                                    "session_id": None,
                                },
                            })

                    elif msg_type == "resume_session":
                        _cancel_stt_tasks(stt_tasks)
                        target_sid = uuid.UUID(data["payload"]["session_id"])
                        # Detach any in-flight task (let agent finish in background)
                        task_running = active_task is not None and not active_task.done()
                        if task_running:
                            detach_event.set()
                            active_task = None
                            detach_event = asyncio.Event()
                            # Set old session to "processing"
                            if active_session_id:
                                old_session = await get_session(db, active_session_id)
                                if old_session:
                                    old_session.status = "processing"
                                    await db.commit()
                        else:
                            await _cancel_active_task(active_task)
                            active_task = None
                        active_session_id = await _do_resume(
                            websocket, db, user_id, target_sid, active_session_id,
                            skip_pause=task_running,
                        )

                    elif msg_type == "stop_session":
                        # Client-initiated turn cancellation. Sends ark's
                        # `stop` command for the currently-active session;
                        # ark's new mid-turn cancel unwinds the turn and
                        # emits `done {stopped: true}` which flows back
                        # through the normal streaming path — no local
                        # task cancellation needed. Silent no-op for
                        # non-ark sessions (no equivalent primitive on
                        # direct-provider paths yet) or when nothing's
                        # in flight for this session.
                        target_sid_raw = data.get("payload", {}).get("session_id")
                        try:
                            target_sid = uuid.UUID(target_sid_raw) if target_sid_raw else None
                        except (ValueError, TypeError):
                            target_sid = None
                        if target_sid is not None:
                            await _forward_stop_to_ark(db, target_sid)

                    elif msg_type == "rename_session":
                        target_sid = uuid.UUID(data["payload"]["session_id"])
                        new_name = data["payload"]["name"]
                        session = await rename_session(db, target_sid, new_name)
                        if session:
                            await websocket.send_json({
                                "type": "session_renamed",
                                "payload": {
                                    "session_id": str(target_sid),
                                    "name": new_name,
                                },
                            })

                    elif msg_type == "update_session_labels":
                        target_sid = uuid.UUID(data["payload"]["session_id"])
                        label_names = data["payload"]["labels"]
                        labels = await set_session_labels(db, target_sid, user_id, label_names)
                        await websocket.send_json({
                            "type": "session_labels_updated",
                            "payload": {
                                "session_id": str(target_sid),
                                "labels": labels,
                            },
                        })

            finally:
                # Detach active task instead of cancelling — let the agent finish
                # in the background. The streaming loop will notice the detach event,
                # stop sending to the (now-closed) WS, and persist the full response.
                if active_task and not active_task.done():
                    detach_event.set()
                _cancel_stt_tasks(stt_tasks)
                recv_task.cancel()

    except WebSocketDisconnect:
        _unregister_connection(user_id, websocket)
        if active_session_id:
            try:
                async with websocket.app.state.db_session() as db:
                    # If an active task is still running, mark session as "processing"
                    # so the background completion logic can take over.
                    task_running = active_task is not None and not active_task.done()
                    session = await get_session(db, active_session_id)
                    if session:
                        session.status = "processing" if task_running else "paused"
                        await db.commit()
            except Exception:
                pass
    except Exception as e:
        _unregister_connection(user_id, websocket)
        try:
            await websocket.send_json(
                {"type": "error", "payload": {"message": str(e)}}
            )
        except Exception:
            pass


async def _transcribe(
    websocket: WebSocket,
    stt,
    audio_data_b64: str,
    audio_format: str,
    no_speech_threshold: float,
    timezone: str | None,
) -> tuple[str, str | None]:
    """Transcribe one audio segment. Returns ("", tz) on failure after
    telling the client, so the caller only has to skip empty text."""
    try:
        audio_bytes = base64.b64decode(audio_data_b64)
        text = await stt.transcribe(audio_bytes, audio_format, no_speech_threshold=no_speech_threshold)
    except Exception as exc:
        logger.warning("STT transcription failed: %r", exc)
        try:
            await websocket.send_json({
                "type": "error",
                "payload": {"message": f"Transcription failed: {exc!r}"},
            })
        except Exception:
            pass
        return "", timezone
    return text.strip(), timezone


def _cancel_stt_tasks(stt_tasks: deque[asyncio.Task]) -> None:
    """Drop pending transcriptions — their text belongs to a context
    (session) the user has just left."""
    for t in stt_tasks:
        t.cancel()
    stt_tasks.clear()


async def _handle_text_own_session(websocket: WebSocket, *args, **kwargs) -> uuid.UUID | None:
    """Run `_handle_text` on a DB session of its own.

    The task is cancelled on interrupt and may outlive the socket when
    detached; on the connection's shared session, a cancel mid-query
    left that session unusable ("Can't reconnect until invalid
    transaction is rolled back") and the main loop would query it
    concurrently with the task.
    """
    async with websocket.app.state.db_session() as task_db:
        return await _handle_text(websocket, task_db, *args, **kwargs)


async def _cancel_active_task(active_task: asyncio.Task | None) -> None:
    """Cancel an in-flight processing task and wait for it to finish."""
    if active_task and not active_task.done():
        active_task.cancel()
        try:
            await active_task
        except (asyncio.CancelledError, Exception):
            pass


async def _forward_stop_to_ark(db, session_id: uuid.UUID) -> None:
    """Send ark's `stop` command for the given Relay session's ark
    backend. No-op when the session isn't ark-backed, has no ark
    session yet (nothing to cancel), or ark isn't reachable. Ark itself
    is a silent no-op if nothing's actually in flight for that
    ark_session_id, so we don't check turn-in-flight state here."""
    from app.db.redis import get_provider_state
    from app.services import agent_manager
    from app.services.llm.ark import get_connection_by_key, _server_id_for

    session = await get_session(db, session_id)
    if session is None:
        return
    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    if agent is None or agent.llm_provider != "ark":
        return
    ark_sid = await get_provider_state(str(session_id), "ark")
    if not ark_sid:
        return
    base_url, api_key = await agent_manager.resolve_llm_config(agent)
    if not base_url:
        return
    key = _server_id_for(base_url.rstrip("/"), api_key)
    conn = get_connection_by_key(key)
    if conn is None:
        return
    try:
        # Do NOT bump the generation — the streaming task is still
        # active and needs to receive ark's `done {stopped: true}` to
        # unwind cleanly. See ArkClientConnection.send_stop for why.
        await conn.send_stop(ark_sid, bump_generation=False)
    except Exception:
        logger.exception("Failed to forward stop to ark session=%s", ark_sid)


async def _handle_text(
    websocket: WebSocket,
    db,
    user_id: str,
    text: str,
    active_session_id: uuid.UUID | None,
    lobby_history: list[dict],
    voice_mode_instructions: str | None = None,
    detach_event: asyncio.Event | None = None,
    is_live_mode: bool = False,
    timezone: str | None = None,
    stream_audio: bool = False,
) -> uuid.UUID | None:
    """Process user text (from typing or STT). Returns updated active_session_id.

    `stream_audio`: the client plays raw PCM, so a provider with a streaming
    connection speaks the whole reply over it instead of per sentence."""
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
        import time as _time_lobby
        _lrid = str(uuid.uuid4())[:8]
        _lt = _time_lobby.perf_counter()
        logger.info("[lobby rid=%s] BEGIN text=%r", _lrid, text[:60])
        events = await handle_lobby_message(db, user_id, text, lobby_history)
        _lobby_ms = (_time_lobby.perf_counter() - _lt) * 1000
        logger.info("[lobby rid=%s] handle_lobby_message: %.1fms (n_events=%d)",
                    _lrid, _lobby_ms, len(events))
        _dt = _time_lobby.perf_counter()
        result = await _dispatch_events(
            websocket, db, user_id, events, active_session_id, lobby_history,
            is_live_mode=is_live_mode,
            _timing_rid=_lrid,
        )
        _dispatch_ms = (_time_lobby.perf_counter() - _dt) * 1000
        _total_ms = (_time_lobby.perf_counter() - _lt) * 1000
        logger.info("[lobby rid=%s] dispatch: %.1fms  TOTAL: %.1fms",
                    _lrid, _dispatch_ms, _total_ms)
        return result

    # Stream session messages with TTS
    ws_lock = asyncio.Lock()
    tts_provider = None
    tts_agent = None
    tts_buffer = ""
    tts_seq = 0
    tts_tasks: list[asyncio.Task] = []
    # Set while a reply is being spoken over a streaming connection:
    # sentences go here and `_stream_tts_turn` sends them on.
    tts_queue: asyncio.Queue | None = None
    # Speaker whose speech is still being synthesized/streamed after its
    # text_done. The reply loop doesn't wait for it — the message must be
    # persisted (it comes after text_done) even if the user barges in while
    # it's being spoken — so its audio_done is sent by `finish_speech`.
    speech_speaker: str | None = None

    async def finish_speech() -> None:
        """Wait out the previous message's speech and close it with
        audio_done, before another message's audio starts or the turn ends."""
        nonlocal tts_tasks, speech_speaker
        if speech_speaker is None:
            return
        if tts_tasks:
            await asyncio.gather(*tts_tasks, return_exceptions=True)
        tts_tasks = []
        async with ws_lock:
            await websocket.send_json({
                "type": "audio_done",
                "payload": {"speaker": speech_speaker},
            })
        speech_speaker = None

    detached = False
    detached_session_id = active_session_id

    try:
        async for event in handle_session_message_stream(db, active_session_id, text, voice_mode_instructions, timezone=timezone):
            # Check if we've been detached (user left mid-stream)
            if not detached and detach_event and detach_event.is_set():
                detached = True
                # Cancel any in-flight TTS tasks — no point synthesizing
                for t in tts_tasks:
                    t.cancel()
                tts_tasks = []
                tts_provider = None
                speech_speaker = None
                logger.info("[WS] detached — finishing stream in background for session %s", detached_session_id)

            etype = event["type"]

            if detached:
                # Silently consume events — conversation_manager still persists messages
                continue

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
                if is_live_mode:
                    await finish_speech()
                    await _tts_for_text(websocket, db, event["payload"]["text"], speaker)
            else:
                await websocket.send_json(event)

            # ── TTS orchestration ──
            # Only synthesise/stream audio when the client is actually in
            # live mode. In text mode nobody listens to the bytes, and
            # every synth call blocks the WS thread for ~500ms+ per call.
            if etype == "text_start" and is_live_mode:
                await finish_speech()
                session = await get_session(db, active_session_id) if active_session_id else None
                if session:
                    tts_agent = await agent_manager.get_agent_by_id(db, session.agent_id)
                    if tts_agent:
                        logger.info(
                            "Stream TTS resolve: agent=%s, tts_provider=%s, voice_id=%s, has_agent_key=%s",
                            tts_agent.name, tts_agent.tts_provider, tts_agent.voice_id, bool(tts_agent.tts_api_key),
                        )
                        from app.services.agent_manager import resolve_tts_config
                        tts_base_url, tts_key = await resolve_tts_config(tts_agent)
                        tts_provider = get_tts_provider(tts_agent.tts_provider, tts_key, base_url=tts_base_url)
                if tts_provider:
                    tts_buffer = ""
                    tts_seq = 0
                    tts_tasks = []
                    tts_semaphore = asyncio.Semaphore(2)
                    tts_queue = None
                    async with ws_lock:
                        await websocket.send_json({
                            "type": "audio_start",
                            "payload": {"speaker": event["payload"]["speaker"]},
                        })
                    if stream_audio:
                        tts_queue = asyncio.Queue()
                        tts_tasks.append(asyncio.create_task(
                            _stream_tts_turn(websocket, ws_lock, tts_provider, tts_agent, tts_queue)
                        ))

            elif etype == "text_delta" and tts_provider and tts_agent:
                tts_buffer += event["payload"]["delta"]
                sentences, tts_buffer = _extract_sentences(tts_buffer)
                for sentence in sentences:
                    if tts_queue is not None:
                        tts_queue.put_nowait(sentence)
                        continue
                    seq = tts_seq
                    tts_seq += 1
                    task = asyncio.create_task(
                        _synth_and_send(websocket, ws_lock, tts_provider, tts_agent, sentence, seq, tts_semaphore)
                    )
                    tts_tasks.append(task)

            elif etype == "text_done" and tts_provider and tts_agent:
                if tts_queue is not None:
                    if tts_buffer.strip():
                        tts_queue.put_nowait(tts_buffer)
                    tts_queue.put_nowait(None)
                    tts_queue = None
                elif tts_buffer.strip():
                    seq = tts_seq
                    tts_seq += 1
                    task = asyncio.create_task(
                        _synth_and_send(websocket, ws_lock, tts_provider, tts_agent, tts_buffer, seq, tts_semaphore)
                    )
                    tts_tasks.append(task)
                speech_speaker = event["payload"]["speaker"]
                tts_provider = None
                tts_agent = None

        if not detached:
            await finish_speech()

    except asyncio.CancelledError:
        # Cancelled mid-turn — clean up in-flight TTS tasks silently
        logger.info("[WS] _handle_text cancelled — cleaning up %d TTS tasks", len(tts_tasks))
        for t in tts_tasks:
            t.cancel()
        if tts_tasks:
            await asyncio.gather(*tts_tasks, return_exceptions=True)
        raise

    # If we were detached, mark the session as unread and broadcast
    if detached and detached_session_id:
        logger.info("[WS] background stream complete for session %s", detached_session_id)
        # Check if the user has re-entered the session — if so, don't mark unread
        current_session = await get_session(db, detached_session_id)
        user_re_entered = current_session is not None and current_session.status == "active"

        if not user_re_entered:
            await mark_session_unread(db, detached_session_id)

        # Generate summary and set status to "paused"
        try:
            await pause_session(db, detached_session_id)
        except Exception:
            pass

        # Broadcast unread only if the user didn't re-enter
        if not user_re_entered:
            await _broadcast_to_user(user_id, {
                "type": "session_unread",
                "payload": {
                    "session_id": str(detached_session_id),
                    "has_unread": True,
                },
            })
        await _broadcast_to_user(user_id, {
            "type": "session_status",
            "payload": {
                "session_id": str(detached_session_id),
                "status": "paused",
            },
        })

    return active_session_id


def _extract_sentences(buffer: str) -> tuple[list[str], str]:
    """Split buffer on sentence/newline boundaries.

    Returns (complete_chunks, remaining_buffer).
    """
    parts = _SENTENCE_RE.split(buffer)
    if len(parts) <= 1:
        return [], buffer
    chunks = [s.strip() for s in parts[:-1] if s.strip()]
    return chunks, parts[-1]


def _clean_for_tts(text: str, *, keep_end_punct: bool = False) -> str:
    """Strip markdown and formatting artifacts before TTS synthesis.

    List item prefixes are stripped; newlines remain so streaming chunks
    (already split per-line by _extract_sentences) sound natural, and
    _tts_for_text benefits from provider-level newline pauses.

    `keep_end_punct`: for streaming providers, which find sentence
    boundaries (and when to start speaking) from the punctuation. A chunk
    without any — a list item, a heading — gets a period so it doesn't run
    into the next one.
    """
    text = _TTS_FENCED_CODE_RE.sub('', text)
    text = _TTS_HEADING_RE.sub('', text)
    text = _TTS_LIST_RE.sub('', text)
    text = _TTS_BOLD_RE.sub(r'\1', text)
    text = _TTS_ITALIC_RE.sub(lambda m: m.group(1) or m.group(2) or '', text)
    text = _TTS_INLINE_CODE_RE.sub(r'\1', text)
    text = _TTS_URL_RE.sub('', text)
    text = _TTS_ELLIPSIS_RE.sub(',', text)
    text = _TTS_EMOJI_RE.sub('', text)
    text = re.sub(r' {2,}', ' ', text)
    if keep_end_punct:
        text = text.strip()
        return text + "." if text and text[-1] not in ".!?:;," else text
    text = _TTS_TRAILING_PUNCT_RE.sub('', text)
    return text.strip()


async def _stream_tts_turn(
    websocket: WebSocket,
    lock: asyncio.Lock,
    provider,
    agent,
    queue: asyncio.Queue,
) -> None:
    """Speak one reply over the provider's streaming connection.

    Sentences arrive on `queue` (None ends the reply) and are sent as they
    come; PCM is forwarded as `pcm16` audio_chunks as soon as it's
    generated. Providers without streaming, or a stream that won't open,
    fall back to per-sentence MP3 so the reply is still spoken. Never
    raises: a TTS failure must not fail the turn.
    """
    seq = 0

    async def send_chunk(data: bytes, fmt: str, sample_rate: int | None = None) -> None:
        nonlocal seq
        payload = {
            "speaker": agent.name,
            "data": base64.b64encode(data).decode(),
            "format": fmt,
            "sequence": seq,
        }
        if sample_rate:
            payload["sample_rate"] = sample_rate
        seq += 1
        async with lock:
            await websocket.send_json({"type": "audio_chunk", "payload": payload})

    try:
        stream = await provider.open_stream(agent.voice_id, agent.voice_settings)
    except Exception as exc:
        logger.warning("TTS stream failed to open, falling back to per-sentence: %r", exc)
        stream = None

    try:
        if stream is None:
            while (text := await queue.get()) is not None:
                clean = _clean_for_tts(text)
                if not clean:
                    continue
                try:
                    audio = await provider.synthesize(clean, agent.voice_id, agent.voice_settings)
                except Exception as exc:
                    logger.warning("TTS synthesis failed (%d chars): %r", len(clean), exc)
                    continue
                await send_chunk(audio, "mp3")
            return

        async def forward_audio() -> None:
            # Frames can split a 16-bit sample; carry the odd byte over so
            # every chunk the client gets is whole samples.
            carry = b""
            async for pcm in stream.audio():
                pcm = carry + pcm
                carry = pcm[-1:] if len(pcm) % 2 else b""
                if carry:
                    pcm = pcm[:-1]
                if pcm:
                    await send_chunk(pcm, "pcm16", stream.sample_rate)

        reader = asyncio.create_task(forward_audio())
        try:
            sent_any = False
            while (text := await queue.get()) is not None:
                if reader.done():
                    break  # stream died; surfaced below
                clean = _clean_for_tts(text, keep_end_punct=True)
                if clean:
                    await stream.send(clean + " ")
                    sent_any = True
            if sent_any and not reader.done():
                await stream.finish()
            if sent_any:
                await reader
        finally:
            reader.cancel()
            try:
                await stream.aclose()
            except Exception:
                pass
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        logger.warning("TTS stream failed mid-reply after %d chunks: %r", seq, exc)


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
    clean = _clean_for_tts(text)
    if not clean:
        return

    try:
        if semaphore:
            await semaphore.acquire()
        try:
            audio_bytes = await provider.synthesize(clean, agent.voice_id, agent.voice_settings)
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
    from app.services.agent_manager import resolve_tts_config
    tts_base_url, api_key = await resolve_tts_config(agent)
    provider = get_tts_provider(agent.tts_provider, api_key, base_url=tts_base_url)
    if not provider:
        logger.warning(
            "TTS: get_tts_provider returned None for provider=%s, has_key=%s",
            agent.tts_provider, bool(api_key),
        )
        return

    clean = _clean_for_tts(text)
    if not clean:
        return

    try:
        await websocket.send_json({
            "type": "audio_start",
            "payload": {"speaker": speaker_name},
        })

        audio_bytes = await provider.synthesize(clean, agent.voice_id, agent.voice_settings)
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
    skip_pause: bool = False,
) -> uuid.UUID | None:
    """Resume a specific session. Returns the new active_session_id."""
    import time as _time
    rid = str(uuid.uuid4())[:8]
    t0 = _time.perf_counter()

    def _lap(label: str) -> None:
        nonlocal t0
        now = _time.perf_counter()
        logger.info("[resume rid=%s] %s: %.1fms", rid, label, (now - t0) * 1000)
        t0 = now

    t_start = _time.perf_counter()
    logger.info("[resume rid=%s] BEGIN target=%s active=%s skip_pause=%s",
                rid, target_sid, active_session_id, skip_pause)

    session = await get_session(db, target_sid)
    _lap("get_session")
    if not session or session.user_id != user_id:
        # Session is gone (auto-pruned, deleted elsewhere, wrong user). Tell the
        # client to clear its in-session UI so its next message doesn't get
        # routed to the lobby while the UI still claims to be in a session.
        await websocket.send_json({
            "type": "session_left",
            "payload": {
                "session_id": None,
                "reason": "session_not_found_on_resume",
                "detail": {
                    "requested_session_id": str(target_sid),
                },
            },
        })
        await websocket.send_json({
            "type": "state_update",
            "payload": {
                "active_speaker": "operator",
                "status": "ready",
                "session_id": None,
            },
        })
        return None

    if active_session_id and not skip_pause:
        await pause_session(db, active_session_id)
        _lap("pause_session")

    was_processing = session.status == "processing"
    session.status = "active"
    if session.has_unread:
        session.has_unread = False
    await db.commit()
    _lap("commit(status=active)")

    # Broadcast read state to all clients
    await _broadcast_to_user(user_id, {
        "type": "session_unread",
        "payload": {"session_id": str(session.session_id), "has_unread": False},
    })
    _lap("broadcast(session_unread)")

    agent = await agent_manager.get_agent_by_id(db, session.agent_id)
    _lap("get_agent_by_id")
    labels = await get_session_labels(db, session.session_id)
    _lap("get_session_labels")
    await websocket.send_json({
        "type": "session_entered",
        "payload": {
            "session_id": str(session.session_id),
            "agent_name": agent.name if agent else "Unknown",
            "labels": labels,
        },
    })
    _lap("send(session_entered)")
    messages = await get_session_messages(db, session.session_id)
    _lap(f"get_session_messages(n={len(messages)})")
    await websocket.send_json({
        "type": "session_history",
        "payload": {"messages": messages},
    })
    _lap("send(session_history)")

    # If the agent is still generating in the background, show thinking indicator
    if was_processing:
        await websocket.send_json({
            "type": "state_update",
            "payload": {
                "active_speaker": agent.name if agent else "agent",
                "status": "processing",
                "session_id": str(session.session_id),
            },
        })
        _lap("send(state_update processing)")

    total_ms = (_time.perf_counter() - t_start) * 1000
    logger.info("[resume rid=%s] END total=%.1fms", rid, total_ms)
    return session.session_id


async def _dispatch_events(
    websocket: WebSocket,
    db,
    user_id: str,
    events: list[dict],
    active_session_id: uuid.UUID | None,
    lobby_history: list[dict],
    is_live_mode: bool = False,
    _timing_rid: str | None = None,
) -> uuid.UUID | None:
    """Send events to client, intercepting internal routing events."""
    import time as _time_de
    for idx, event in enumerate(events):
        etype = event["type"]
        _et = _time_de.perf_counter()

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
            _tt = _time_de.perf_counter()
            await websocket.send_json(event)
            _send_ms = (_time_de.perf_counter() - _tt) * 1000
            _tts_ms = 0.0
            if is_live_mode:
                _tt = _time_de.perf_counter()
                await _tts_for_text(websocket, db, event["payload"]["text"], speaker)
                _tts_ms = (_time_de.perf_counter() - _tt) * 1000
            if _timing_rid:
                logger.info(
                    "[lobby rid=%s]   evt[%d] text(speaker=%s, %d chars): send=%.1fms tts=%.1fms live=%s",
                    _timing_rid, idx, speaker, len(event["payload"]["text"]),
                    _send_ms, _tts_ms, is_live_mode,
                )
            continue

        else:
            await websocket.send_json(event)

        if _timing_rid:
            logger.info(
                "[lobby rid=%s]   evt[%d] %s: %.1fms",
                _timing_rid, idx, etype, (_time_de.perf_counter() - _et) * 1000,
            )

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
