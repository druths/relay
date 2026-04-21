/**
 * Wire protocol types for the WebSocket connection between the
 * OpenClaw channel plugin and the Relay backend.
 */

// ── Relay → Plugin (inbound to OpenClaw) ──

export interface UserMessageEvent {
  type: "user_message";
  sessionId: string;
  userId: string;
  text: string;
  /** URLs of files uploaded to Relay, accessible by the agent */
  fileUrls?: string[];
  timestamp: string;
}

// ── Plugin → Relay (outbound from OpenClaw) ──

export interface AgentTextEvent {
  type: "agent_text";
  sessionId: string;
  agentId: string;
  text: string;
  timestamp: string;
}

export interface AgentMediaEvent {
  type: "agent_media";
  sessionId: string;
  agentId: string;
  /** URL to download the file (workspace URL or external) */
  mediaUrl: string;
  /** Original filename */
  filename: string;
  /** MIME type if known */
  mimeType?: string;
  /** Optional caption/text accompanying the file */
  caption?: string;
  timestamp: string;
}

export interface AgentStatusEvent {
  type: "agent_status";
  sessionId: string;
  agentId: string;
  status: "thinking" | "typing" | "idle";
  timestamp: string;
}

export interface PluginHelloEvent {
  type: "hello";
  pluginVersion: string;
  agentId: string;
  token: string;
}

export interface RelayWelcomeEvent {
  type: "welcome";
  relayVersion: string;
  agentId: string;
}

export interface RelayErrorEvent {
  type: "error";
  message: string;
  code?: string;
}

export type PluginToRelayEvent = AgentTextEvent | AgentMediaEvent | AgentStatusEvent | PluginHelloEvent;
export type RelayToPluginEvent = UserMessageEvent | RelayWelcomeEvent | RelayErrorEvent;
