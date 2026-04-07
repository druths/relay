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
}

export interface Message {
  message_id?: string;
  role: string;
  text_content: string;
  created_at?: string;
  streaming?: boolean;
  interrupted?: boolean;
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
  | WsError;
