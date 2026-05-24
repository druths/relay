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
  // Only default to JSON for string bodies. FormData / Blob / etc. need the
  // browser to set Content-Type itself (FormData includes the multipart
  // boundary parameter, which we can't construct here).
  if (!headers.has("Content-Type") && typeof init?.body === "string") {
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

/**
 * Upload one or more files to `/v1/files` for the given session and invoke
 * `onAttachment` for each successful response. Used by both the paperclip
 * button and the App-level drag-and-drop target so they stay in sync.
 */
export async function uploadFiles(
  files: FileList | File[],
  sessionId: string | null | undefined,
  onAttachment: (att: import("./types").FileAttachment) => void,
): Promise<void> {
  const qs = sessionId ? `?session_id=${encodeURIComponent(sessionId)}` : "";
  const list = Array.from(files);
  for (const file of list) {
    const form = new FormData();
    form.append("file", file);
    try {
      const resp = await apiFetch(`/v1/files${qs}`, { method: "POST", body: form });
      if (!resp.ok) {
        console.error("Upload failed", resp.status, await resp.text());
        continue;
      }
      const att = await resp.json();
      onAttachment(att);
    } catch (err) {
      console.error("Upload error", err);
    }
  }
}
