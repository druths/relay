import { useCallback, useEffect, useRef, useState } from "react";
import type { Agent, Message, Session, WsEvent } from "../types";
import { useAudioPlayer } from "./useAudioPlayer";
import { apiFetch, getWsUrl } from "../api";

export interface RelayState {
  connected: boolean;
  activeSessionId: string | null;
  activeAgentName: string | null;
  activeSessionLabels: string[];
  activeSpeaker: string;
  status: string;
  lobbyMessages: Message[];
  sessionMessages: Message[];
  agents: Agent[];
  sessions: Session[];
  sttAvailable: boolean;
}

export function useRelay() {
  const ws = useRef<WebSocket | null>(null);
  const audioPlayer = useAudioPlayer();
  const audioPlayerRef = useRef(audioPlayer);
  audioPlayerRef.current = audioPlayer;

  const [state, setState] = useState<RelayState>({
    connected: false,
    activeSessionId: null,
    activeAgentName: null,
    activeSessionLabels: [],
    activeSpeaker: "operator",
    status: "idle",
    lobbyMessages: [],
    sessionMessages: [],
    agents: [],
    sessions: [],
    sttAvailable: false,
  });

  // Fetch agent list
  const refreshAgents = useCallback(async () => {
    try {
      const res = await apiFetch("/v1/agents?include_operator=true");
      const agents: Agent[] = await res.json();
      setState((s) => ({ ...s, agents }));
    } catch {
      // ignore
    }
  }, []);

  useEffect(() => {
    refreshAgents();
  }, [refreshAgents]);

  // Fetch sessions list
  const fetchSessions = useCallback(async () => {
    try {
      const res = await apiFetch("/v1/sessions");
      const sessions: Session[] = await res.json();
      setState((s) => ({ ...s, sessions }));
    } catch {
      // ignore
    }
  }, []);

  // Reconnection state
  const intentionalDisconnect = useRef(false);
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const reconnectDelay = useRef(1000);

  // Connect to lobby
  const connect = useCallback(() => {
    // Clean up any pending reconnect
    if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
    // Close existing socket if any
    if (ws.current && ws.current.readyState <= WebSocket.OPEN) {
      ws.current.close();
    }

    const socket = new WebSocket(getWsUrl("/v1/lobby"));

    socket.onopen = () => {
      reconnectDelay.current = 1000; // Reset backoff on success
      setState((s) => ({ ...s, connected: true }));
      fetchSessions();
      refreshAgents();
      apiFetch("/v1/agents/stt/status")
        .then((r) => r.json())
        .then((data: { available: boolean }) =>
          setState((s) => ({ ...s, sttAvailable: data.available }))
        )
        .catch(() => {});
    };

    socket.onclose = () => {
      setState((s) => ({ ...s, connected: false, status: "disconnected" }));
      // Auto-reconnect unless intentionally disconnected
      if (!intentionalDisconnect.current) {
        const delay = reconnectDelay.current;
        reconnectDelay.current = Math.min(delay * 2, 30000); // Exponential backoff, max 30s
        reconnectTimer.current = setTimeout(() => {
          console.log(`[WS] Reconnecting in ${delay}ms...`);
          connect();
        }, delay);
      }
    };

    socket.onmessage = (ev) => {
      const event: WsEvent = JSON.parse(ev.data);

      switch (event.type) {
        case "state_update":
          setState((s) => {
            const next: typeof s = {
              ...s,
              activeSpeaker: event.payload.active_speaker,
              status: event.payload.status,
            };
            // If we were streaming and the turn ended without text_done, mark interrupted
            if (event.payload.status !== "processing") {
              const msgs = [...s.sessionMessages];
              const last = msgs[msgs.length - 1];
              if (last?.streaming) {
                msgs[msgs.length - 1] = { ...last, streaming: false, interrupted: true };
                next.sessionMessages = msgs;
              }
            }
            return next;
          });
          break;

        case "text":
          setState((s) => {
            if (s.activeSessionId) {
              return {
                ...s,
                sessionMessages: [
                  ...s.sessionMessages,
                  {
                    role: event.payload.speaker === "operator" ? "operator" : "agent",
                    text_content: event.payload.text,
                  },
                ],
              };
            }
            return {
              ...s,
              lobbyMessages: [
                ...s.lobbyMessages,
                { role: "operator", text_content: event.payload.text },
              ],
            };
          });
          break;

        case "handoff":
          break;

        case "session_entered":
          setState((s) => ({
            ...s,
            activeSessionId: event.payload.session_id,
            activeAgentName: event.payload.agent_name,
            activeSessionLabels: event.payload.labels || [],
            sessionMessages: [],
          }));
          fetchSessions();
          break;

        case "session_left":
          audioPlayerRef.current.stop();
          setState((s) => ({
            ...s,
            activeSessionId: null,
            activeAgentName: null,
            activeSessionLabels: [],
            sessionMessages: [],
          }));
          fetchSessions();
          break;

        case "session_history":
          setState((s) => ({
            ...s,
            sessionMessages: event.payload.messages,
          }));
          break;

        case "text_start":
          setState((s) => {
            if (s.activeSessionId) {
              return {
                ...s,
                sessionMessages: [
                  ...s.sessionMessages,
                  {
                    role: "agent",
                    text_content: "",
                    streaming: true,
                  },
                ],
              };
            }
            return s;
          });
          break;

        case "text_delta":
          setState((s) => {
            if (!s.activeSessionId) return s;
            const msgs = [...s.sessionMessages];
            const last = msgs[msgs.length - 1];
            if (last && last.streaming) {
              msgs[msgs.length - 1] = {
                ...last,
                text_content: last.text_content + event.payload.delta,
              };
            }
            return { ...s, sessionMessages: msgs };
          });
          break;

        case "text_done":
          setState((s) => {
            if (!s.activeSessionId) return s;
            const msgs = [...s.sessionMessages];
            const last = msgs[msgs.length - 1];
            if (last && last.streaming) {
              msgs[msgs.length - 1] = {
                ...last,
                text_content: event.payload.text,
                streaming: false,
              };
            }
            return { ...s, sessionMessages: msgs };
          });
          break;

        case "session_named":
          setState((s) => ({
            ...s,
            sessions: s.sessions.map((sess) =>
              sess.session_id === event.payload.session_id
                ? { ...sess, name: event.payload.name }
                : sess
            ),
          }));
          break;

        case "session_renamed":
          setState((s) => ({
            ...s,
            sessions: s.sessions.map((sess) =>
              sess.session_id === event.payload.session_id
                ? { ...sess, name: event.payload.name }
                : sess
            ),
          }));
          break;

        case "session_labels_updated":
          setState((s) => ({
            ...s,
            sessions: s.sessions.map((sess) =>
              sess.session_id === event.payload.session_id
                ? { ...sess, labels: event.payload.labels }
                : sess
            ),
            activeSessionLabels:
              s.activeSessionId === event.payload.session_id
                ? event.payload.labels
                : s.activeSessionLabels,
          }));
          break;

        case "session_status":
          setState((s) => ({
            ...s,
            sessions: s.sessions.map((sess) =>
              sess.session_id === event.payload.session_id
                ? { ...sess, status: event.payload.status }
                : sess
            ),
          }));
          break;

        case "session_unread":
          setState((s) => ({
            ...s,
            sessions: s.sessions.map((sess) =>
              sess.session_id === event.payload.session_id
                ? { ...sess, has_unread: event.payload.has_unread }
                : sess
            ),
          }));
          break;

        case "session_deleted":
          audioPlayerRef.current.stop();
          setState((s) => ({
            ...s,
            sessions: s.sessions.filter(
              (sess) => sess.session_id !== event.payload.session_id
            ),
            activeSessionId:
              s.activeSessionId === event.payload.session_id
                ? null
                : s.activeSessionId,
            activeAgentName:
              s.activeSessionId === event.payload.session_id
                ? null
                : s.activeAgentName,
            activeSessionLabels:
              s.activeSessionId === event.payload.session_id
                ? []
                : s.activeSessionLabels,
            sessionMessages:
              s.activeSessionId === event.payload.session_id
                ? []
                : s.sessionMessages,
          }));
          break;

        case "audio_start":
          audioPlayerRef.current.start();
          break;

        case "audio_chunk":
          audioPlayerRef.current.enqueue(event.payload.data, event.payload.sequence);
          break;

        case "audio_done":
          audioPlayerRef.current.done();
          break;

        case "transcription":
          console.log(`[STT] transcription received: "${event.payload.text}"`);
          setState((s) => {
            if (s.activeSessionId) {
              return {
                ...s,
                sessionMessages: [
                  ...s.sessionMessages,
                  { role: "user", text_content: event.payload.text },
                ],
              };
            }
            return {
              ...s,
              lobbyMessages: [
                ...s.lobbyMessages,
                { role: "user", text_content: event.payload.text },
              ],
            };
          });
          break;

        case "error":
          console.error("Relay error:", event.payload.message);
          break;
      }
    };

    ws.current = socket;
  }, [fetchSessions]);

  // Auto-connect on mount, reconnect on visibility change, cleanup on unmount
  useEffect(() => {
    connect();

    // Reconnect immediately when tab becomes visible (e.g., laptop wake)
    const handleVisibility = () => {
      if (document.visibilityState === "visible" && (!ws.current || ws.current.readyState !== WebSocket.OPEN)) {
        reconnectDelay.current = 1000;
        connect();
      }
    };
    document.addEventListener("visibilitychange", handleVisibility);

    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      intentionalDisconnect.current = true;
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
      audioPlayerRef.current.stop();
      ws.current?.close();
      ws.current = null;
    };
  }, [connect]);

  // Disconnect from lobby
  const disconnect = useCallback(() => {
    intentionalDisconnect.current = true;
    if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
    audioPlayerRef.current.stop();
    ws.current?.close();
    ws.current = null;
    setState((s) => ({
      ...s,
      connected: false,
      activeSessionId: null,
      activeAgentName: null,
      activeSessionLabels: [],
      lobbyMessages: [],
      sessionMessages: [],
      sessions: [],
      status: "idle",
      activeSpeaker: "operator",
    }));
  }, []);

  // Send text message (routes to lobby or session based on server state)
  const sendMessage = useCallback((text: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;

    // Add user message to the appropriate list
    setState((s) => {
      if (s.activeSessionId) {
        return {
          ...s,
          sessionMessages: [...s.sessionMessages, { role: "user", text_content: text }],
        };
      }
      return {
        ...s,
        lobbyMessages: [...s.lobbyMessages, { role: "user", text_content: text }],
      };
    });

    ws.current.send(JSON.stringify({ type: "text_input", payload: { text } }));
  }, []);

  // Send audio for STT transcription
  const sendAudio = useCallback((audioBase64: string, format: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) {
      console.warn("[STT] WebSocket not open, cannot send audio");
      return;
    }
    console.log(`[STT] sending audio_input: ${audioBase64.length} base64 chars, format=${format}`);
    ws.current.send(
      JSON.stringify({ type: "audio_input", payload: { data: audioBase64, format } })
    );
  }, []);

  // Leave current agent session, return to lobby
  const leaveSession = useCallback(() => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(JSON.stringify({ type: "leave_session" }));
  }, []);

  // Resume a specific session by ID
  const resumeSession = useCallback((sessionId: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(
      JSON.stringify({ type: "resume_session", payload: { session_id: sessionId } })
    );
  }, []);

  // Delete a session by ID
  const deleteSession = useCallback(async (sessionId: string) => {
    await apiFetch(`/v1/sessions/${sessionId}`, { method: "DELETE" });
    setState((s) => {
      const next = {
        ...s,
        sessions: s.sessions.filter((sess) => sess.session_id !== sessionId),
      };
      if (s.activeSessionId === sessionId) {
        next.activeSessionId = null;
        next.activeAgentName = null;
        next.activeSessionLabels = [];
        next.sessionMessages = [];
        next.activeSpeaker = "operator";
        next.status = "ready";
      }
      return next;
    });
  }, []);

  // Rename a session
  const renameSession = useCallback((sessionId: string, name: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(
      JSON.stringify({ type: "rename_session", payload: { session_id: sessionId, name } })
    );
  }, []);

  // Update session labels
  const updateSessionLabels = useCallback((sessionId: string, labels: string[]) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(
      JSON.stringify({ type: "update_session_labels", payload: { session_id: sessionId, labels } })
    );
  }, []);

  // Update agent config
  const updateAgentConfig = useCallback(
    async (agentId: string, config: { voice_settings?: Record<string, number>; voice_id?: string; tts_provider?: string; persona_prompt?: string }) => {
      const res = await apiFetch(`/v1/agents/${agentId}/config`, {
        method: "PATCH",
        body: JSON.stringify(config),
      });
      const updated: Agent = await res.json();
      setState((s) => ({
        ...s,
        agents: s.agents.map((a) => (a.agent_id === agentId ? updated : a)),
      }));
    },
    []
  );

  const stopAudio = useCallback(() => {
    audioPlayerRef.current.stop();
  }, []);

  const toggleMute = useCallback(() => {
    audioPlayerRef.current.setMuted(!audioPlayerRef.current.muted);
  }, []);

  return {
    ...state,
    connect,
    disconnect,
    sendMessage,
    sendAudio,
    leaveSession,
    resumeSession,
    deleteSession,
    renameSession,
    updateSessionLabels,
    updateAgentConfig,
    refreshAgents,
    fetchSessions,
    stopAudio,
    muted: audioPlayer.muted,
    toggleMute,
  };
}

