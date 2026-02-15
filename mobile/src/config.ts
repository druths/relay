// Relay backend URLs.
// Override at build time via EXPO_PUBLIC_API_URL / EXPO_PUBLIC_WS_URL env vars,
// or edit the defaults below for local development.

export const API_BASE =
  process.env.EXPO_PUBLIC_API_URL || "http://localhost:8000";

export const WS_BASE =
  process.env.EXPO_PUBLIC_WS_URL || "ws://localhost:8000";
