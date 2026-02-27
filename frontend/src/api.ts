import { getToken, clearToken } from "./hooks/useAuth";

export const API_BASE = import.meta.env.VITE_API_URL || "http://localhost:8000";
export const WS_BASE = import.meta.env.VITE_WS_URL || "ws://localhost:8000";

export async function apiFetch(
  path: string,
  init?: RequestInit,
): Promise<Response> {
  const token = getToken();
  const headers = new Headers(init?.headers);
  if (token) {
    headers.set("Authorization", `Bearer ${token}`);
  }
  if (!headers.has("Content-Type") && init?.body) {
    headers.set("Content-Type", "application/json");
  }

  const res = await fetch(`${API_BASE}${path}`, { ...init, headers });

  if (res.status === 401) {
    clearToken();
    window.location.reload();
  }

  return res;
}

export function getWsUrl(path: string): string {
  const token = getToken();
  return `${WS_BASE}${path}?token=${token}`;
}
