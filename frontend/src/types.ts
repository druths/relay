export interface Agent {
  agent_id: string;
  name: string;
  persona_prompt: string;
  tts_provider: string;
  voice_id: string;
  voice_settings: Record<string, number>;
  llm_provider: string;
  llm_model: string;
  llm_base_url: string | null;
  llm_api_key: string | null;
  tts_api_key: string | null;
  is_operator: boolean;
  sort_order: number;
  status: "healthy" | "error" | "unknown";
  status_message: string;
}

export interface PlatformSettings {
  stt_provider: string;
  stt_api_key: string | null;
  stt_silence_threshold_db: number;
  stt_silence_timeout_ms: number;
  stt_min_duration_ms: number;
  stt_no_speech_threshold: number;
  tts_default_provider: string;
  tts_openai_api_key: string | null;
  tts_elevenlabs_api_key: string | null;
}

export interface Session {
  session_id: string;
  agent_id: string;
  agent_name: string;
  status: string;
  created_at: string;
  last_active: string;
  name: string | null;
  summary: string | null;
  labels: string[];
  has_unread: boolean;
  /** External-system session ids, keyed by provider. e.g. `ark` → the ark
   * server-side session id used by `post_to_session` and cron entries. */
  provider_state?: Record<string, string>;
  /** Optional ark project binding. `project_server_id` disambiguates the
   * project_id across multiple ark backends. */
  project_id?: string | null;
  project_server_id?: string | null;
}

/** ark project — fetched via the Relay passthrough `GET /v1/projects`. */
export interface Project {
  id: string;
  name: string;
  description?: string | null;
  project_context?: string | null;
  root?: string;
  created_at?: string;
  deleted_at?: string | null;
  /** Set by Relay's aggregator so subsequent ops can be routed to the right
   * ark backend. */
  server_id: string;
}

/** One entry in a directory listing returned by `GET /projects/{id}/files/...`
 * or `GET /agents/{id}/workspace/files/...`. */
export interface DirEntry {
  name: string;
  is_dir: boolean;
  size: number;
  mtime: number;
}

export interface DirListing {
  path: string;
  entries: DirEntry[];
}

export interface FileAttachment {
  file_id: string;
  filename: string;
  mime_type: string;
  size_bytes: number;
  url: string;
}

export interface MessageMetadata {
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    context_window?: number;
    model?: string;
  };
  /** Set on `role: "compaction"` marker rows. Reason strings match
   * ark's: `auto:proactive`, `auto:reactive`, `client-invoked`,
   * `client-supplied`, or a `disabled:*` variant. */
  reason?: string;
  /** Set on `role: "project_change"` marker rows. Both endpoints may
   *  be null (detach / first-time-assign). Names are the human labels
   *  ark resolved at change-time so they stay correct across renames. */
  from_project_id?: string | null;
  to_project_id?: string | null;
  from_project_name?: string | null;
  to_project_name?: string | null;
  /** Set on `role: "error"` marker rows. `code` is ark's classified
   *  RunError kind (`context_too_long` / `rate_limit` / `auth` /
   *  `token_budget_exceeded` / `other`); `message` is the raw provider
   *  text — the divider renders both so users can copy details into
   *  bug reports without leaving the app. */
  code?: string;
  message?: string;
}

export interface Message {
  message_id?: string;
  role: string;
  text_content: string;
  created_at?: string;
  streaming?: boolean;
  interrupted?: boolean;
  attachments?: FileAttachment[];
  /** Per-message diagnostics (e.g. ark token usage). Empty/absent on
   * messages that pre-date the diagnostics work or come from providers
   * that don't report usage. */
  metadata?: MessageMetadata;
}

// WebSocket event types

export interface WsStateUpdate {
  type: "state_update";
  payload: {
    active_speaker: string;
    status: string;
    session_id: string | null;
  };
}

export interface WsTextEvent {
  type: "text";
  payload: {
    speaker: string;
    text: string;
    /** Set when the event targets a specific session (e.g. ark
     * injected_message). If absent, the event applies to the user's current
     * conversation context. */
    session_id?: string;
  };
}

export interface WsHandoffEvent {
  type: "handoff";
  payload: {
    from: string;
    to: string;
    play_earcon: boolean;
  };
}

export interface WsSessionEntered {
  type: "session_entered";
  payload: {
    session_id: string;
    agent_name: string;
    labels: string[];
  };
}

export interface WsSessionLeft {
  type: "session_left";
  payload: {
    session_id: string | null;
  };
}

export interface WsSessionHistory {
  type: "session_history";
  payload: {
    messages: Message[];
  };
}

export interface WsSessionNamed {
  type: "session_named";
  payload: {
    session_id: string;
    name: string;
  };
}

export interface WsTextStart {
  type: "text_start";
  payload: {
    speaker: string;
  };
}

export interface WsTextDelta {
  type: "text_delta";
  payload: {
    speaker: string;
    delta: string;
  };
}

export interface WsTextDone {
  type: "text_done";
  payload: {
    speaker: string;
    text: string;
    metadata?: MessageMetadata;
  };
}

export interface WsAudioStart {
  type: "audio_start";
  payload: {
    speaker: string;
  };
}

export interface WsAudioChunk {
  type: "audio_chunk";
  payload: {
    speaker: string;
    data: string;
    format: string;
    sequence: number;
  };
}

export interface WsAudioDone {
  type: "audio_done";
  payload: {
    speaker: string;
  };
}

export interface WsTranscription {
  type: "transcription";
  payload: {
    text: string;
  };
}

export interface WsSessionRenamed {
  type: "session_renamed";
  payload: {
    session_id: string;
    name: string;
  };
}

export interface WsSessionLabelsUpdated {
  type: "session_labels_updated";
  payload: {
    session_id: string;
    labels: string[];
  };
}

export interface WsSessionDeleted {
  type: "session_deleted";
  payload: {
    session_id: string;
  };
}

export interface WsSessionStatus {
  type: "session_status";
  payload: {
    session_id: string;
    status: string;
  };
}

export interface WsSessionUnread {
  type: "session_unread";
  payload: {
    session_id: string;
    has_unread: boolean;
  };
}

export interface WsError {
  type: "error";
  payload: {
    message: string;
  };
}

export interface WsAgentFile {
  type: "agent_file";
  payload: {
    session_id: string;
    agent_name: string;
    path: string;
    description?: string | null;
    size?: number | null;
  };
}

/** Live event from ark when a project's filesystem changes. Forwarded
 * verbatim by the Relay backend; clients filter by `project_id`. */
export interface WsProjectFileChanged {
  type: "project_file_changed";
  payload: {
    type?: "project_file_changed";
    project_id: string;
    path: string;
    change: "created" | "modified" | "deleted";
  };
}

/** Live event from ark when an agent workspace's filesystem changes. */
export interface WsWorkspaceFileChanged {
  type: "workspace_file_changed";
  payload: {
    type?: "workspace_file_changed";
    agent_name: string;
    path: string;
    change: "created" | "modified" | "deleted";
  };
}

// ── Session compaction ─────────────────────────────────────────────
// Relay forwards ark's four compaction events verbatim (plus session_id
// and agent_name for routing). Clients render a "compacting…" chip
// between `_started` and `_completed`/`_failed`/`_skipped`, and a
// divider in the transcript when a `compaction`-role marker arrives.

export interface WsCompactionStarted {
  type: "compaction_started";
  payload: {
    session_id: string;
    agent_name: string;
    reason: string;
    input_tokens: number | null;
    context_window: number | null;
    model: string | null;
  };
}

export interface WsCompactionCompleted {
  type: "compaction_completed";
  payload: {
    session_id: string;
    agent_name: string;
    reason: string;
    summary: string;
  };
}

export interface WsCompactionFailed {
  type: "compaction_failed";
  payload: {
    session_id: string;
    agent_name: string;
    reason: string;
    code: string;
    message: string;
  };
}

export interface WsCompactionSkipped {
  type: "compaction_skipped";
  payload: {
    session_id: string;
    agent_name: string;
    reason: string;
    input_tokens: number | null;
    context_window: number | null;
  };
}

// ── Agent activity ────────────────────────────────────────────────
// Streamed mid-turn from ark: "thinking" (streaming deltas of the
// model's internal reasoning), "tool_call" (structured invocation),
// and "tool_result" (the invocation's output). Each event carries
// the raw ark payload verbatim so clients can render as much detail
// as they want. Clients accumulate into a per-turn activity list
// that clears on text_done / new user send.

/** Fires when a session's turn terminates with a `RunError`. Clients
 *  should sweep any in-flight streaming bubble to interrupted and drop
 *  a divider into the transcript with the error code + message. Codes
 *  match ark's RunError set — `context_too_long`, `rate_limit`, `auth`,
 *  `token_budget_exceeded`, `other`. */
export interface WsSessionError {
  type: "session_error";
  payload: {
    session_id: string;
    agent_name: string;
    code: string;
    message: string;
    /** Server-composed "code: message" label so all clients render the
     *  same divider text. */
    marker_text: string;
  };
}

/** Fires when a session's ark project binding is (re)assigned or
 *  detached. Only real changes emit — no-op PATCHes are silent. Clients
 *  should update the session's `project_id` in place and drop a
 *  divider into the transcript at the marker's arrival point. */
export interface WsSessionProjectChanged {
  type: "session_project_changed";
  payload: {
    session_id: string;
    agent_name: string;
    from_project_id: string | null;
    from_project_name: string | null;
    to_project_id: string | null;
    to_project_name: string | null;
    /** Server-pre-composed label so all clients render the same text
     *  ("Project changed: A → B", "Project set: X", "Project cleared…"). */
    marker_text: string;
    changed_at: number | null;
  };
}

export type AgentActivityKind = "thinking" | "tool_call" | "tool_result";

export interface WsAgentActivity {
  type: "agent_activity";
  payload: {
    session_id: string;
    speaker: string;
    kind: AgentActivityKind;
    /** Raw ark event body. Shapes:
     *  - thinking: `{ type: "thinking", delta: string }`
     *  - tool_call: `{ type: "tool_call", id, name, input }`
     *  - tool_result: `{ type: "tool_result", id, output, error }`
     */
    detail: Record<string, unknown>;
  };
}

export type WsEvent =
  | WsStateUpdate
  | WsTextEvent
  | WsHandoffEvent
  | WsSessionEntered
  | WsSessionLeft
  | WsSessionHistory
  | WsSessionNamed
  | WsTextStart
  | WsTextDelta
  | WsTextDone
  | WsAudioStart
  | WsAudioChunk
  | WsAudioDone
  | WsTranscription
  | WsSessionRenamed
  | WsSessionLabelsUpdated
  | WsSessionDeleted
  | WsSessionStatus
  | WsSessionUnread
  | WsAgentFile
  | WsProjectFileChanged
  | WsWorkspaceFileChanged
  | WsCompactionStarted
  | WsCompactionCompleted
  | WsCompactionFailed
  | WsCompactionSkipped
  | WsAgentActivity
  | WsSessionProjectChanged
  | WsSessionError
  | WsError;
