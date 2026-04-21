import type { UserMessageEvent } from "./types.js";

/**
 * MessageEnvelope is the standard OpenClaw inbound message format.
 * We define the shape here since we use openclaw as a peerDependency
 * and can't import types directly at build time.
 */
export interface MessageEnvelope {
  id: string;
  timestamp: string;
  channelId: string;
  accountId: string;
  sender: {
    id: string;
    name: string;
    avatar?: string;
  };
  content: {
    text: string;
    mediaUrls?: string[];
  };
  metadata: Record<string, unknown>;
  conversationId?: string;
}

/**
 * Convert a Relay user message into an OpenClaw MessageEnvelope.
 */
export function normalizeUserMessage(event: UserMessageEvent): MessageEnvelope {
  let text = event.text;

  // If files are attached, append them as references the agent can access
  if (event.fileUrls && event.fileUrls.length > 0) {
    const fileRefs = event.fileUrls
      .map((url) => `[Attached file: ${url}]`)
      .join("\n");
    text = text ? `${text}\n\n${fileRefs}` : fileRefs;
  }

  return {
    id: `relay-${event.sessionId}-${Date.now()}`,
    timestamp: event.timestamp,
    channelId: "openclaw-channel",
    accountId: "default",
    sender: {
      id: event.userId,
      name: event.userId,
    },
    content: {
      text,
      mediaUrls: event.fileUrls,
    },
    metadata: {
      sessionId: event.sessionId,
      source: "relay",
    },
    conversationId: event.sessionId,
  };
}
