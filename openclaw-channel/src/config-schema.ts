import { Type, type Static } from "@sinclair/typebox";

export const RelayChannelConfigSchema = Type.Object({
  /** WebSocket URL of the Relay backend (e.g., ws://relay-host:5051/v1/channel) */
  relayUrl: Type.String({
    description: "WebSocket URL of the Relay backend",
    default: "ws://localhost:5051/v1/channel",
  }),
  /** Authentication token for the Relay backend */
  apiKey: Type.String({
    description: "API key for authenticating with the Relay backend",
    default: "",
  }),
  /** Reconnection settings */
  reconnectBaseMs: Type.Number({
    description: "Base delay for reconnection in milliseconds",
    default: 3000,
  }),
  reconnectMaxMs: Type.Number({
    description: "Maximum reconnection delay in milliseconds",
    default: 300000, // 5 minutes
  }),
  reconnectMultiplier: Type.Number({
    description: "Backoff multiplier for reconnection",
    default: 2,
  }),
  /** Keep-alive ping interval */
  pingIntervalMs: Type.Number({
    description: "WebSocket ping interval in milliseconds",
    default: 30000,
  }),
});

export type RelayChannelConfig = Static<typeof RelayChannelConfigSchema>;
