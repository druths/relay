"""WebSocket endpoint for the OpenClaw channel plugin.

The plugin (running inside OpenClaw on a remote machine) connects here
and maintains a persistent bidirectional WebSocket. Agent responses flow
from the plugin to Relay, and user messages flow from Relay to the plugin.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.api.auth import verify_ws_token
from app.db.redis import cache_session_context, invalidate_session_cache
from app.services.conversation_manager import (
    get_session,
    mark_session_unread,
)

logger = logging.getLogger(__name__)

router = APIRouter()

# ── Plugin connection registry ─────────────────────────────────────────
# Maps agent_id (str) → set of connected plugin WebSockets.
# When the plugin sends a "hello" with its agentId, we register it here.
# When user messages need to reach the agent, we look up the plugin WS.

_plugin_connections: dict[str, WebSocket] = {}


def get_plugin_ws(agent_id: str) -> WebSocket | None:
    """Get the plugin WebSocket for a given agent ID, if connected."""
    return _plugin_connections.get(agent_id)


def is_plugin_connected(agent_id: str) -> bool:
    return agent_id in _plugin_connections


async def send_to_plugin(agent_id: str, event: dict) -> bool:
    """Send an event to the OpenClaw plugin for a given agent."""
    ws = _plugin_connections.get(agent_id)
    if not ws:
        logger.warning("No plugin connection for agent %s", agent_id)
        return False
    try:
        await ws.send_json(event)
        return True
    except Exception as exc:
        logger.warning("Failed to send to plugin for agent %s: %s", agent_id, exc)
        return False


# ── User-facing broadcast registry ─────────────────────────────────────
# Import the user broadcast function from the lobby websocket module
# so we can push agent responses to connected clients.

from app.api.websocket import _broadcast_to_user


# ── Plugin WebSocket endpoint ──────────────────────────────────────────

@router.websocket("/v1/channel")
async def channel_ws(websocket: WebSocket, token: str = Query("")):
    """WebSocket endpoint for the OpenClaw channel plugin."""
    await websocket.accept()

    agent_id: str | None = None

    try:
        # Wait for hello message with authentication
        raw = await asyncio.wait_for(websocket.receive_text(), timeout=10)
        hello = json.loads(raw)

        if hello.get("type") != "hello":
            await websocket.send_json({"type": "error", "message": "Expected hello message"})
            await websocket.close(code=4001)
            return

        # Verify the token
        plugin_token = hello.get("token", "")
        try:
            verify_ws_token(plugin_token)
        except (ValueError, Exception):
            # Also accept the raw API key from channel config
            if token and token == plugin_token:
                pass  # Direct token match
            else:
                await websocket.send_json({"type": "error", "message": "Authentication failed"})
                await websocket.close(code=4001)
                return

        agent_id = hello.get("agentId", "default")
        plugin_version = hello.get("pluginVersion", "unknown")

        logger.info("[Channel] Plugin connected: agent=%s version=%s", agent_id, plugin_version)

        # Register the connection
        _plugin_connections[agent_id] = websocket

        # Send welcome
        await websocket.send_json({
            "type": "welcome",
            "relayVersion": "1.0.0",
            "agentId": agent_id,
        })

        # Message loop
        while True:
            raw = await websocket.receive_text()
            data = json.loads(raw)
            msg_type = data.get("type")

            if msg_type == "agent_text":
                await _handle_agent_text(websocket, data)

            elif msg_type == "agent_media":
                await _handle_agent_media(websocket, data)

            elif msg_type == "agent_status":
                await _handle_agent_status(websocket, data)

            else:
                logger.debug("[Channel] Unknown message type from plugin: %s", msg_type)

    except asyncio.TimeoutError:
        logger.warning("[Channel] Plugin did not send hello within timeout")
        try:
            await websocket.close(code=4000, reason="Hello timeout")
        except Exception:
            pass
    except WebSocketDisconnect:
        logger.info("[Channel] Plugin disconnected: agent=%s", agent_id)
    except Exception as exc:
        logger.error("[Channel] Error: %s", exc)
        try:
            await websocket.send_json({"type": "error", "message": str(exc)})
        except Exception:
            pass
    finally:
        if agent_id and _plugin_connections.get(agent_id) is websocket:
            del _plugin_connections[agent_id]
            logger.info("[Channel] Unregistered plugin for agent=%s", agent_id)


# ── Event handlers ─────────────────────────────────────────────────────

async def _handle_agent_text(ws: WebSocket, data: dict) -> None:
    """Agent sent a text response — route to the user's session."""
    session_id = data.get("sessionId", "")
    text = data.get("text", "")
    agent_id = data.get("agentId", "agent")

    if not session_id or not text:
        return

    logger.info("[Channel] Agent text for session %s (%d chars)", session_id, len(text))

    # Persist the message
    async with _get_db() as db:
        from app.services.conversation_manager import _persist_message
        await _persist_message(db, uuid.UUID(session_id), "agent", text)
        await invalidate_session_cache(session_id)

        # Mark as unread (the user may not be watching this session)
        await mark_session_unread(db, uuid.UUID(session_id))

        # Get the session to find the user
        session = await get_session(db, uuid.UUID(session_id))
        if not session:
            return

    # Broadcast to all connected clients for this user
    await _broadcast_to_user(session.user_id, {
        "type": "text",
        "payload": {"speaker": agent_id, "text": text},
    })
    await _broadcast_to_user(session.user_id, {
        "type": "session_unread",
        "payload": {"session_id": session_id, "has_unread": True},
    })


async def _handle_agent_media(ws: WebSocket, data: dict) -> None:
    """Agent sent a file — download/cache it and notify the user."""
    session_id = data.get("sessionId", "")
    media_url = data.get("mediaUrl", "")
    filename = data.get("filename", "file")
    mime_type = data.get("mimeType", "")
    caption = data.get("caption", "")
    agent_id = data.get("agentId", "agent")

    if not session_id or not media_url:
        return

    logger.info("[Channel] Agent media for session %s: %s (%s)", session_id, filename, mime_type)

    # Build a text message with the file reference
    # TODO: Download and re-host the file via the files API
    text = caption or ""
    if media_url:
        text = f"{text}\n[File: {filename}]({media_url})".strip()

    async with _get_db() as db:
        from app.services.conversation_manager import _persist_message
        msg = await _persist_message(db, uuid.UUID(session_id), "agent", text)
        # Store media info in metadata
        msg.metadata_ = {
            "media_url": media_url,
            "filename": filename,
            "mime_type": mime_type,
        }
        await db.commit()
        await invalidate_session_cache(session_id)
        await mark_session_unread(db, uuid.UUID(session_id))

        session = await get_session(db, uuid.UUID(session_id))
        if not session:
            return

    await _broadcast_to_user(session.user_id, {
        "type": "text",
        "payload": {"speaker": agent_id, "text": text},
    })
    await _broadcast_to_user(session.user_id, {
        "type": "session_unread",
        "payload": {"session_id": session_id, "has_unread": True},
    })


async def _handle_agent_status(ws: WebSocket, data: dict) -> None:
    """Agent status update (thinking, typing, idle)."""
    session_id = data.get("sessionId", "")
    status = data.get("status", "idle")
    agent_id = data.get("agentId", "agent")

    if not session_id:
        return

    # Map to Relay status
    relay_status = "processing" if status in ("thinking", "typing") else "ready"

    async with _get_db() as db:
        session = await get_session(db, uuid.UUID(session_id))
        if not session:
            return

    await _broadcast_to_user(session.user_id, {
        "type": "state_update",
        "payload": {
            "active_speaker": agent_id,
            "status": relay_status,
            "session_id": session_id,
        },
    })


# ── DB helper ──────────────────────────────────────────────────────────

def _get_db():
    """Get an async DB session. Must be used as: async with _get_db() as db:"""
    from app.db.database import async_session
    return async_session()
