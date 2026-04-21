import { createRelayChannel } from "./channel.js";
import { RelayChannelConfigSchema } from "./config-schema.js";

/**
 * OpenClaw channel plugin entry point.
 *
 * When installed in an OpenClaw instance, this plugin registers a "Relay"
 * channel that maintains a persistent WebSocket connection to the Relay
 * backend, enabling bidirectional messaging with file support.
 */
export default {
  id: "openclaw-channel",
  name: "Relay Channel",

  register(api: any) {
    const channel = createRelayChannel();

    api.registerChannel({
      ...channel,
      configSchema: RelayChannelConfigSchema,
    });
  },
};
