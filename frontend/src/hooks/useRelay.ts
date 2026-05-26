import { useCallback, useEffect, useRef, useState } from "react";
import type { Agent, Message, Project, Session, WsEvent } from "../types";
import { useAudioPlayer } from "./useAudioPlayer";
import { apiFetch, getWsUrl, listProjects } from "../api";

/** A single file-change event observed on the WS, kept in a small ring
 * buffer so the workspace/project panel can render a "recent changes" feed
 * without re-fetching the directory listing. */
export interface FileChangeEvent {
  ts: number;
  kind: "project" | "workspace";
  scope: string; // project_id or agent_name
  path: string;
  change: "created" | "modified" | "deleted";
}

const FILE_CHANGE_BUFFER_SIZE = 200;

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
  allLabels: string[];
  sttAvailable: boolean;
  projects: Project[];
  fileChanges: FileChangeEvent[];
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
    allLabels: [],
    sttAvailable: false,
    projects: [],
    fileChanges: [],
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

  // Fetch ark projects (aggregated across every configured ark backend).
  // Quietly tolerates the no-ark-configured case — the response is just an
  // empty list, so the rest of the UI stays calm.
  const refreshProjects = useCallback(async () => {
    try {
      const projects = await listProjects();
      setState((s) => ({ ...s, projects }));
    } catch {
      // ignore — non-ark setups won't have projects
    }
  }, []);

  useEffect(() => {
    refreshAgents();
    refreshProjects();
  }, [refreshAgents, refreshProjects]);

  // Fetch all labels across the user's sessions (not just the 20 most-recent).
  const fetchLabels = useCallback(async () => {
    try {
      const res = await apiFetch("/v1/labels");
      const labels: { label_id: string; name: string }[] = await res.json();
      setState((s) => ({ ...s, allLabels: labels.map((l) => l.name).sort() }));
    } catch {
      // ignore
    }
  }, []);

  // Fetch sessions list. When `search` or `label` is non-empty, the server
  // returns matches beyond the default 20 most-recent.
  const fetchSessions = useCallback(async (opts?: { search?: string; label?: string }) => {
    try {
      const params = new URLSearchParams();
      if (opts?.search) params.set("search", opts.search);
      if (opts?.label) params.set("label", opts.label);
      const qs = params.toString();
      const res = await apiFetch(`/v1/sessions${qs ? `?${qs}` : ""}`);
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
  // Tracks current activeSessionId so reconnect callbacks can re-resume.
  const activeSessionIdRef = useRef<string | null>(null);
  activeSessionIdRef.current = state.activeSessionId;
  // Suppress the operator greeting + its TTS audio after a reconnect — the
  // greeting is sent unconditionally on every new WS connection and would
  // otherwise pollute the active session's conversation log.
  const suppressNextGreeting = useRef(false);
  const suppressNextAudio = useRef(false);

  // Connect to lobby
  const connect = useCallback(() => {
    // Clean up any pending reconnect
    if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
    // Close existing socket if any
    if (ws.current && ws.current.readyState <= WebSocket.OPEN) {
      ws.current.close();
    }

    // Capture the in-session state BEFORE opening the new socket so the
    // onopen callback can decide whether this is a reconnect-mid-session.
    const resumingSessionId = activeSessionIdRef.current;
    if (resumingSessionId) {
      suppressNextGreeting.current = true;
      suppressNextAudio.current = true;
    }

    const socket = new WebSocket(getWsUrl("/v1/lobby"));

    socket.onopen = () => {
      reconnectDelay.current = 1000; // Reset backoff on success
      setState((s) => ({ ...s, connected: true }));
      fetchSessions();
      fetchLabels();
      refreshAgents();
      apiFetch("/v1/agents/stt/status")
        .then((r) => r.json())
        .then((data: { available: boolean }) =>
          setState((s) => ({ ...s, sttAvailable: data.available }))
        )
        .catch(() => {});
      // Re-establish the previously-active session on the server side so
      // subsequent messages aren't routed to the lobby.
      if (resumingSessionId) {
        socket.send(JSON.stringify({
          type: "resume_session",
          payload: { session_id: resumingSessionId },
        }));
      }
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
          if (suppressNextGreeting.current && event.payload.speaker === "operator") {
            suppressNextGreeting.current = false;
            break;
          }
          setState((s) => {
            // If the event is targeted at a specific session and that
            // session isn't the one we're currently in, ignore the live
            // broadcast — the message has already been persisted on the
            // server, the unread badge will signal the user, and
            // history-on-resume will replay it when they navigate over.
            if (
              event.payload.session_id &&
              event.payload.session_id !== s.activeSessionId
            ) {
              return s;
            }
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
                    created_at: new Date().toISOString(),
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
                // Attach the diagnostics metadata (token usage etc.) the
                // server reports at end of turn so the Diagnostics view can
                // render it on this bubble.
                ...(event.payload.metadata ? { metadata: event.payload.metadata } : {}),
                created_at: last.created_at ?? new Date().toISOString(),
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
          fetchLabels();
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

        case "agent_file": {
          // The agent shared a workspace file. Render it as an agent message
          // with a file attachment so it appears inline in the conversation.
          const path = event.payload.path;
          const filename = path.split("/").pop() || path;
          const attachment = {
            file_id: "",  // we don't have a Relay file_id for agent-pushed files
            filename,
            mime_type: "application/octet-stream",
            size_bytes: event.payload.size ?? 0,
            // Relay-internal proxy URL: /v1/files supports ark fetch only by
            // file_id, so we use a direct path-based variant here. The download
            // route below interprets `agent/path` form.
            url: `/v1/files/ark/${encodeURIComponent(event.payload.agent_name)}/${path.split("/").map(encodeURIComponent).join("/")}`,
          };
          setState((s) => {
            if (s.activeSessionId !== event.payload.session_id) return s;
            return {
              ...s,
              sessionMessages: [
                ...s.sessionMessages,
                {
                  role: "agent",
                  text_content: event.payload.description || "",
                  attachments: [attachment],
                },
              ],
            };
          });
          break;
        }

        case "audio_start":
          if (suppressNextAudio.current) break;
          audioPlayerRef.current.start();
          break;

        case "audio_chunk":
          if (suppressNextAudio.current) break;
          audioPlayerRef.current.enqueue(event.payload.data, event.payload.sequence);
          break;

        case "audio_done":
          if (suppressNextAudio.current) {
            suppressNextAudio.current = false;
            break;
          }
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

        case "project_file_changed": {
          // Backend forwards the raw ark event verbatim under `payload`. ark
          // emits flat events, so it may also nest as `payload.payload` —
          // tolerate both for safety.
          const p = (event.payload as { payload?: typeof event.payload }).payload ?? event.payload;
          setState((s) => ({
            ...s,
            fileChanges: [
              ...s.fileChanges.slice(-(FILE_CHANGE_BUFFER_SIZE - 1)),
              {
                ts: Date.now(),
                kind: "project",
                scope: p.project_id,
                path: p.path,
                change: p.change,
              },
            ],
          }));
          break;
        }

        case "workspace_file_changed": {
          const p = (event.payload as { payload?: typeof event.payload }).payload ?? event.payload;
          setState((s) => ({
            ...s,
            fileChanges: [
              ...s.fileChanges.slice(-(FILE_CHANGE_BUFFER_SIZE - 1)),
              {
                ts: Date.now(),
                kind: "workspace",
                scope: p.agent_name,
                path: p.path,
                change: p.change,
              },
            ],
          }));
          break;
        }

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
    const now = new Date().toISOString();
    setState((s) => {
      if (s.activeSessionId) {
        return {
          ...s,
          sessionMessages: [...s.sessionMessages, { role: "user", text_content: text, created_at: now }],
        };
      }
      return {
        ...s,
        lobbyMessages: [...s.lobbyMessages, { role: "user", text_content: text, created_at: now }],
      };
    });

    ws.current.send(JSON.stringify({ type: "text_input", payload: { text } }));
  }, []);

  // Append a user attachment to the conversation log. The file is already
  // uploaded server-side (and proxied to ark if applicable); this just makes
  // it visible. Returns no events to the server — ark already knows about
  // the upload via the REST POST path.
  const appendUserAttachment = useCallback((attachment: import("../types").FileAttachment) => {
    setState((s) => {
      const msg: Message = { role: "user", text_content: "", attachments: [attachment] };
      if (s.activeSessionId) {
        return { ...s, sessionMessages: [...s.sessionMessages, msg] };
      }
      return { ...s, lobbyMessages: [...s.lobbyMessages, msg] };
    });
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
    refreshProjects,
    fetchSessions,
    fetchLabels,
    appendUserAttachment,
    stopAudio,
    muted: audioPlayer.muted,
    toggleMute,
  };
}

