import WebSocket from "ws";
import type { RelayChannelConfig } from "./config-schema.js";
import type {
  PluginToRelayEvent,
  RelayToPluginEvent,
  UserMessageEvent,
} from "./types.js";

export interface AdapterCallbacks {
  onUserMessage: (event: UserMessageEvent) => void;
  onConnected: () => void;
  onDisconnected: () => void;
  log: (level: "info" | "warn" | "error", message: string) => void;
}

/**
 * Manages the persistent WebSocket connection from the OpenClaw plugin
 * to the Relay backend. Handles reconnection with exponential backoff.
 */
export class RelayAdapter {
  private ws: WebSocket | null = null;
  private config: RelayChannelConfig;
  private agentId: string;
  private callbacks: AdapterCallbacks;
  private reconnectDelay: number;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private intentionalClose = false;

  constructor(config: RelayChannelConfig, agentId: string, callbacks: AdapterCallbacks) {
    this.config = config;
    this.agentId = agentId;
    this.callbacks = callbacks;
    this.reconnectDelay = config.reconnectBaseMs;
  }

  connect(): void {
    this.intentionalClose = false;
    this.callbacks.log("info", `Connecting to Relay at ${this.config.relayUrl}...`);

    try {
      this.ws = new WebSocket(this.config.relayUrl);
    } catch (err) {
      this.callbacks.log("error", `Failed to create WebSocket: ${err}`);
      this.scheduleReconnect();
      return;
    }

    this.ws.on("open", () => {
      this.callbacks.log("info", "WebSocket connected, sending hello...");
      this.reconnectDelay = this.config.reconnectBaseMs;

      // Authenticate
      this.send({
        type: "hello",
        pluginVersion: "0.1.0",
        agentId: this.agentId,
        token: this.config.apiKey,
      });

      // Start keep-alive pings
      this.startPing();
    });

    this.ws.on("message", (data) => {
      try {
        const event: RelayToPluginEvent = JSON.parse(data.toString());
        this.handleEvent(event);
      } catch (err) {
        this.callbacks.log("warn", `Failed to parse message: ${err}`);
      }
    });

    this.ws.on("close", (code, reason) => {
      this.callbacks.log("info", `WebSocket closed: ${code} ${reason}`);
      this.stopPing();
      this.callbacks.onDisconnected();
      if (!this.intentionalClose) {
        this.scheduleReconnect();
      }
    });

    this.ws.on("error", (err) => {
      this.callbacks.log("error", `WebSocket error: ${err.message}`);
    });
  }

  disconnect(): void {
    this.intentionalClose = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.stopPing();
    if (this.ws) {
      this.ws.close(1000, "Plugin shutting down");
      this.ws = null;
    }
  }

  send(event: PluginToRelayEvent): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      this.callbacks.log("warn", `Cannot send: WebSocket not open (state=${this.ws?.readyState})`);
      return false;
    }
    try {
      this.ws.send(JSON.stringify(event));
      return true;
    } catch (err) {
      this.callbacks.log("error", `Failed to send: ${err}`);
      return false;
    }
  }

  get isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  private handleEvent(event: RelayToPluginEvent): void {
    switch (event.type) {
      case "welcome":
        this.callbacks.log("info", `Relay accepted connection (version=${event.relayVersion})`);
        this.callbacks.onConnected();
        break;
      case "user_message":
        this.callbacks.onUserMessage(event);
        break;
      case "error":
        this.callbacks.log("error", `Relay error: ${event.message} (code=${event.code})`);
        break;
      default:
        this.callbacks.log("warn", `Unknown event type: ${(event as any).type}`);
    }
  }

  private scheduleReconnect(): void {
    if (this.intentionalClose) return;
    this.callbacks.log("info", `Reconnecting in ${this.reconnectDelay}ms...`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectDelay = Math.min(
        this.reconnectDelay * this.config.reconnectMultiplier,
        this.config.reconnectMaxMs,
      );
      this.connect();
    }, this.reconnectDelay);
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.ping();
      }
    }, this.config.pingIntervalMs);
  }

  private stopPing(): void {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }
}
