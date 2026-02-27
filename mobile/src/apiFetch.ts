import { getToken, clearToken } from "./auth";
import { API_BASE, WS_BASE } from "./config";

let _onAuthFailure: (() => void) | null = null;

export function setOnAuthFailure(cb: () => void): void {
  _onAuthFailure = cb;
}

export async function apiFetch(
  path: string,
  init?: RequestInit,
): Promise<Response> {
  const token = await getToken();
  const headers = new Headers(init?.headers);
  if (token) {
    headers.set("Authorization", `Bearer ${token}`);
  }
  if (!headers.has("Content-Type") && init?.body) {
    headers.set("Content-Type", "application/json");
  }

  const res = await fetch(`${API_BASE}${path}`, { ...init, headers });

  if (res.status === 401) {
    await clearToken();
    _onAuthFailure?.();
  }

  return res;
}

export async function getWsUrl(path: string): Promise<string> {
  const token = await getToken();
  return `${WS_BASE}${path}?token=${token}`;
}
