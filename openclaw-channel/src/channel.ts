import { RelayAdapter, type AdapterCallbacks } from "./adapter.js";
import { normalizeUserMessage } from "./normalizer.js";
import type { RelayChannelConfig } from "./config-schema.js";
import type { AgentMediaEvent, AgentTextEvent, UserMessageEvent } from "./types.js";

/**
 * Creates the channel definition object for registerChannel().
 *
 * The actual OpenClaw plugin API types are resolved at runtime via
 * peerDependencies — we define the shape structurally here.
 */
export function createRelayChannel() {
  let adapter: RelayAdapter | null = null;
  let onInboundMessage: ((envelope: any) => void) | null = null;

  return {
    id: "openclaw-channel",

    meta: {
      label: "Relay",
      icon: "🔁",
      description: "Connects to the Relay voice-first AI orchestrator",
    },

    capabilities: {
      chatTypes: ["direct"] as const,
      media: true,
      threads: false,
      reactions: false,
    },

    config: {
      listAccountIds: () => ["default"],
      resolveAccount: (accountId: string, config: RelayChannelConfig) => ({
        id: accountId,
        ...config,
      }),
      isConfigured: (config: RelayChannelConfig) => !!config.relayUrl,
      describeAccount: (accountId: string) => ({
        label: `Relay (${accountId})`,
      }),
    },

    outbound: {
      deliveryMode: "push" as const,

      sendText: async (
        to: string,
        text: string,
        options: { accountId: string; sessionId?: string; log?: (...args: any[]) => void },
      ) => {
        if (!adapter?.isConnected) {
          throw new Error("Relay adapter not connected");
        }

        const event: AgentTextEvent = {
          type: "agent_text",
          sessionId: to,
          agentId: options.accountId,
          text,
          timestamp: new Date().toISOString(),
        };

        const sent = adapter.send(event);
        if (!sent) throw new Error("Failed to send text to Relay");

        return { messageId: `relay-${Date.now()}`, success: true };
      },

      sendMedia: async (
        to: string,
        mediaUrl: string,
        options: {
          accountId: string;
          sessionId?: string;
          caption?: string;
          filename?: string;
          mimeType?: string;
          mediaReadFile?: (path: string) => Promise<Buffer>;
          log?: (...args: any[]) => void;
        },
      ) => {
        if (!adapter?.isConnected) {
          throw new Error("Relay adapter not connected");
        }

        const event: AgentMediaEvent = {
          type: "agent_media",
          sessionId: to,
          agentId: options.accountId,
          mediaUrl,
          filename: options.filename || mediaUrl.split("/").pop() || "file",
          mimeType: options.mimeType,
          caption: options.caption,
          timestamp: new Date().toISOString(),
        };

        const sent = adapter.send(event);
        if (!sent) throw new Error("Failed to send media to Relay");

        return { messageId: `relay-media-${Date.now()}`, success: true };
      },
    },

    gateway: {
      startAccount: (
        accountId: string,
        config: RelayChannelConfig,
        deps: {
          onMessage: (envelope: any) => void;
          log: (...args: any[]) => void;
        },
      ) => {
        onInboundMessage = deps.onMessage;

        const callbacks: AdapterCallbacks = {
          onUserMessage: (event: UserMessageEvent) => {
            const envelope = normalizeUserMessage(event);
            if (onInboundMessage) {
              onInboundMessage(envelope);
            }
          },
          onConnected: () => {
            deps.log("info", "Relay channel connected and ready");
          },
          onDisconnected: () => {
            deps.log("warn", "Relay channel disconnected");
          },
          log: (level, message) => {
            deps.log(level, `[relay-adapter] ${message}`);
          },
        };

        adapter = new RelayAdapter(config, accountId, callbacks);
        adapter.connect();

        // Return a cleanup function
        return () => {
          adapter?.disconnect();
          adapter = null;
          onInboundMessage = null;
        };
      },
    },

    status: {
      defaultRuntime: "running" as const,
      collectStatusIssues: (config: RelayChannelConfig) => {
        const issues: string[] = [];
        if (!config.relayUrl) issues.push("relayUrl is not configured");
        return issues;
      },
    },
  };
}
