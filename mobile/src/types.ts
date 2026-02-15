export interface Agent {
  agent_id: string;
  name: string;
  persona_prompt: string;
  tts_provider: string;
  voice_id: string;
  voice_settings: Record<string, number>;
  llm_provider: string;
  llm_model: string;
  status: "healthy" | "error" | "unknown";
  status_message: string;
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
}

export interface Message {
  message_id?: string;
  role: string;
  text_content: string;
  created_at?: string;
  streaming?: boolean;
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
  | WsError;
