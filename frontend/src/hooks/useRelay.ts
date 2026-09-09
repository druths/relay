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

/** Compaction-in-flight snapshot per session. Set on `compaction_started`,
 *  cleared on `_completed`/`_failed`/`_skipped`. Keyed by Relay
 *  session_id so a background compaction on a non-active session doesn't
 *  bleed into the current session's UI. */
export interface CompactingState {
  reason: string;
  inputTokens: number | null;
  contextWindow: number | null;
}

/** Ark's mid-turn activity: thinking traces, tool calls, tool results.
 *  Client accumulates these into a per-turn list for the "what is the
 *  agent doing right now" strip. Cleared on text_done / user send. */
export type AgentActivity =
  | { kind: "thinking"; text: string; ts: number }
  | { kind: "tool_call"; id: string; name: string; input: unknown; ts: number }
  | { kind: "tool_result"; id: string; output: unknown; error: boolean; ts: number };

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
  /** Map of Relay session_id → in-flight compaction snapshot. */
  compacting: Record<string, CompactingState>;
  /** Ark activity events for the currently-running agent turn. Cleared
   *  when the turn ends (text_done) or the user sends a new message. */
  activities: AgentActivity[];
  /** Distinct labels + project_ids in use across ALL of the user's
   *  sessions, not just the loaded 20-most-recent slice. Powers the
   *  sidebar filter dropdowns so values on older sessions remain
   *  filter-selectable. */
  sessionFacets: { labels: string[]; projectIds: string[] };
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
    compacting: {},
    activities: [],
    sessionFacets: { labels: [], projectIds: [] },
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

  // Fetch sessions list. When any of `search` / `label` / `project` is
  // non-empty, the server returns matches beyond the default 20-most-
  // recent so older filtered sessions remain reachable.
  const fetchSessions = useCallback(async (opts?: { search?: string; label?: string; project?: string }) => {
    try {
      const params = new URLSearchParams();
      if (opts?.search) params.set("search", opts.search);
      if (opts?.label) params.set("label", opts.label);
      if (opts?.project) params.set("project", opts.project);
      const qs = params.toString();
      const res = await apiFetch(`/v1/sessions${qs ? `?${qs}` : ""}`);
      const sessions: Session[] = await res.json();
      setState((s) => ({ ...s, sessions }));
    } catch {
      // ignore
    }
  }, []);

  // Fetch distinct labels + project_ids across the user's full session
  // history — powers the sidebar filter dropdowns so values on older
  // sessions (past the 20-most-recent cap) are still selectable.
  const fetchSessionFacets = useCallback(async () => {
    try {
      const res = await apiFetch("/v1/sessions/facets");
      const facets: { labels: string[]; project_ids: string[] } = await res.json();
      setState((s) => ({
        ...s,
        sessionFacets: { labels: facets.labels, projectIds: facets.project_ids },
      }));
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
      fetchSessionFacets();
      refreshAgents();
      refreshProjects();
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
              const isAgent = event.payload.speaker !== "operator";
              // Only cross-session injected `text` events carry a
              // `session_id` in payload — that's what distinguishes
              // them from the session's own greetings/responses.
              // We tag the message with the source speaker only in
              // that case, so the header appears exclusively for
              // different-agent injections and not for ordinary
              // agent turns.
              const isInjected = !!event.payload.session_id;
              return {
                ...s,
                sessionMessages: [
                  ...s.sessionMessages,
                  {
                    role: isAgent ? "agent" : "operator",
                    text_content: event.payload.text,
                    ...(isAgent && isInjected && event.payload.speaker
                      ? { metadata: { speaker: event.payload.speaker } }
                      : {}),
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
            activities: [],
          }));
          fetchSessions();
          // A freshly-created session can introduce a new project_id
          // the facets endpoint didn't know about.
          fetchSessionFacets();
          break;

        case "session_left":
          audioPlayerRef.current.stop();
          setState((s) => ({
            ...s,
            activeSessionId: null,
            activeAgentName: null,
            activeSessionLabels: [],
            sessionMessages: [],
            activities: [],
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
              // Defensive: any prior bubble still marked streaming was
              // orphaned (a cancelled turn that never emitted its
              // text_done, or a race between state_update and text_start).
              // Close them so their thinking dots go away instead of
              // lingering behind the new turn's bubble.
              const swept = s.sessionMessages.map((m) =>
                m.streaming ? { ...m, streaming: false, interrupted: true } : m
              );
              return {
                ...s,
                sessionMessages: [
                  ...swept,
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
            // Once visible text starts flowing, hide the activity strip
            // — the bubble itself is now the progress indicator. Any
            // mid-response tool call re-populates it. Preserve
            // reference-identity when already empty so we don't churn
            // a re-render on every delta.
            const activities = s.activities.length === 0 ? s.activities : [];
            return { ...s, sessionMessages: msgs, activities };
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
                // Set when the server-side stopped this turn (client
                // pressed Stop → ark fired `done {stopped: true}`).
                // MessageBubble already renders the interrupted state.
                ...(event.payload.interrupted ? { interrupted: true } : {}),
                // Attach the diagnostics metadata (token usage etc.) the
                // server reports at end of turn so the Diagnostics view can
                // render it on this bubble.
                ...(event.payload.metadata ? { metadata: event.payload.metadata } : {}),
                created_at: last.created_at ?? new Date().toISOString(),
              };
            }
            // Turn's over — clear the "current activity" strip. The
            // activities were only relevant while the agent was still
            // working; the bubble now shows the response itself.
            return { ...s, sessionMessages: msgs, activities: [] };
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
          fetchSessionFacets();
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
          // Delete may have removed the last session with a given
          // label or project — refresh so those drop out of the filter
          // dropdowns.
          fetchSessionFacets();
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
            // Workspace reference — enables tap-to-open-in-editor for
            // openable file types. History replay populates these
            // fields from File.storage_path server-side, so the
            // behavior is consistent between live and reloaded views.
            kind: "workspace" as const,
            scope: event.payload.agent_name,
            path,
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

        case "agent_activity":
          setState((s) => {
            // Ignore activity for a non-active session — the strip
            // only reflects what the currently-viewed session is doing.
            if (event.payload.session_id !== s.activeSessionId) return s;
            const detail = event.payload.detail as Record<string, unknown>;
            const now = Date.now();
            if (event.payload.kind === "thinking") {
              const delta = String(detail.delta ?? "");
              // Accumulate consecutive thinking deltas into a single
              // activity entry — otherwise we'd get a new row per token.
              const last = s.activities[s.activities.length - 1];
              if (last && last.kind === "thinking") {
                const updated: AgentActivity = { ...last, text: last.text + delta, ts: now };
                return { ...s, activities: [...s.activities.slice(0, -1), updated] };
              }
              return { ...s, activities: [...s.activities, { kind: "thinking", text: delta, ts: now }] };
            }
            if (event.payload.kind === "tool_call") {
              return {
                ...s,
                activities: [...s.activities, {
                  kind: "tool_call",
                  id: String(detail.id ?? ""),
                  name: String(detail.name ?? "tool"),
                  input: detail.input,
                  ts: now,
                }],
              };
            }
            if (event.payload.kind === "tool_result") {
              return {
                ...s,
                activities: [...s.activities, {
                  kind: "tool_result",
                  id: String(detail.id ?? ""),
                  output: detail.output,
                  error: Boolean(detail.error),
                  ts: now,
                }],
              };
            }
            return s;
          });
          break;

        case "compaction_started":
          setState((s) => ({
            ...s,
            compacting: {
              ...s.compacting,
              [event.payload.session_id]: {
                reason: event.payload.reason,
                inputTokens: event.payload.input_tokens,
                contextWindow: event.payload.context_window,
              },
            },
          }));
          break;

        case "compaction_completed":
          setState((s) => {
            const nextCompacting = { ...s.compacting };
            delete nextCompacting[event.payload.session_id];
            // Append the summary marker to sessionMessages only if this
            // event is for the currently-active session; other sessions'
            // markers will be picked up next time they're resumed
            // (session_history includes persisted `compaction`-role rows).
            const isActive = s.activeSessionId === event.payload.session_id;
            const nextMessages = isActive
              ? [...s.sessionMessages, {
                  role: "compaction",
                  text_content: event.payload.summary,
                  created_at: new Date().toISOString(),
                  metadata: { reason: event.payload.reason },
                }]
              : s.sessionMessages;
            return {
              ...s,
              compacting: nextCompacting,
              sessionMessages: nextMessages,
            };
          });
          break;

        case "compaction_failed":
        case "compaction_skipped":
          setState((s) => {
            const nextCompacting = { ...s.compacting };
            delete nextCompacting[event.payload.session_id];
            return { ...s, compacting: nextCompacting };
          });
          if (event.type === "compaction_failed") {
            console.error(
              "[compaction] failed:", event.payload.code, event.payload.message,
            );
          }
          break;

        case "session_error":
          setState((s) => {
            // Only surface inline if it concerns the currently-open
            // session; other sessions pick the marker up next resume
            // via session_history. Sweep any streaming bubble first —
            // an in-flight turn that died deserves an interrupted
            // marker so the thinking dots don't linger, then drop the
            // error divider immediately below.
            const isActive = s.activeSessionId === event.payload.session_id;
            if (!isActive) return s;
            const swept = s.sessionMessages.map((m) =>
              m.streaming ? { ...m, streaming: false, interrupted: true } : m
            );
            return {
              ...s,
              sessionMessages: [
                ...swept,
                {
                  role: "error",
                  text_content: event.payload.marker_text,
                  created_at: new Date().toISOString(),
                  metadata: {
                    code: event.payload.code,
                    message: event.payload.message,
                  },
                },
              ],
              activities: [],
            };
          });
          break;

        case "session_project_changed":
          setState((s) => {
            // Mirror the new binding into the session list so the chip
            // and filter dropdowns update without a refetch. Only
            // append the divider message to the active session — other
            // sessions will pick it up on their next resume via
            // session_history.
            const nextSessions = s.sessions.map((sess) =>
              sess.session_id === event.payload.session_id
                ? { ...sess, project_id: event.payload.to_project_id }
                : sess,
            );
            const isActive = s.activeSessionId === event.payload.session_id;
            const nextMessages = isActive
              ? [...s.sessionMessages, {
                  role: "project_change",
                  text_content: event.payload.marker_text,
                  created_at: new Date().toISOString(),
                  metadata: {
                    from_project_id: event.payload.from_project_id,
                    to_project_id: event.payload.to_project_id,
                    from_project_name: event.payload.from_project_name,
                    to_project_name: event.payload.to_project_name,
                  },
                }]
              : s.sessionMessages;
            return { ...s, sessions: nextSessions, sessionMessages: nextMessages };
          });
          fetchSessionFacets();
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
    const now = new Date().toISOString();
    setState((s) => {
      if (s.activeSessionId) {
        // Sending a follow-up implicitly interrupts any in-flight agent
        // turn. Close its streaming bubble locally right now so the
        // "thinking" dots go away immediately — the backend will cancel
        // the old task, but that takes a round-trip; meanwhile the
        // client should reflect the interrupt visually.
        const swept = s.sessionMessages.map((m) =>
          m.streaming ? { ...m, streaming: false, interrupted: true } : m
        );
        return {
          ...s,
          sessionMessages: [...swept, { role: "user", text_content: text, created_at: now }],
          // Wipe any leftover activity from the interrupted turn so the
          // strip doesn't stale-render into the new turn.
          activities: [],
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

  /// Ask the backend to stop the currently-running turn on this ark
  /// session. Ark's mid-turn cancel unwinds the turn and emits a
  /// terminal `done {stopped: true}` which lands back here as a
  /// `text_done` with `interrupted: true` — so the streaming bubble
  /// gets its interrupted affordance via the existing text_done
  /// path. Silent no-op for non-ark sessions or when nothing's in
  /// flight (backend enforces both).
  const stopSession = useCallback((sessionId: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(
      JSON.stringify({ type: "stop_session", payload: { session_id: sessionId } })
    );
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

  /// Trigger ark session compaction. The visible UI update (chip on,
  /// divider added after) arrives via the WS event stream, not this
  /// call's return.
  const compactSession = useCallback(async (sessionId: string) => {
    const { compactSession: doCompact } = await import("../api");
    return doCompact(sessionId);
  }, []);

  /// Reassign / detach a session's ark project binding. Ark echoes the
  /// change over the WS (`session_project_changed`), which drives the
  /// session-list chip refresh + transcript divider. We return the
  /// updated session so the caller can await + close its dialog once
  /// the write is durable.
  const setSessionProject = useCallback(async (
    sessionId: string, projectId: string | null,
  ) => {
    const { setSessionProject: doSet } = await import("../api");
    const updated = await doSet(sessionId, projectId);
    // Update the row immediately so callers don't have to wait for the
    // WS event to reflect the change in the sidebar.
    setState((s) => ({
      ...s,
      sessions: s.sessions.map((sess) =>
        sess.session_id === sessionId
          ? { ...sess, project_id: updated.project_id ?? null,
                       project_server_id: updated.project_server_id ?? null }
          : sess,
      ),
    }));
    // The project the session used to be bound to may have just lost
    // its last session; the new one may just have gained its first.
    // Refresh so filter dropdowns don't lag behind.
    fetchSessionFacets();
    return updated;
  }, [fetchSessionFacets]);

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
    compactSession,
    setSessionProject,
    stopSession,
  };
}

