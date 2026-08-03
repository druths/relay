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

// ── ark projects + filesystem passthrough helpers ─────────────────────

import type { Project, DirListing } from "./types";

export async function listProjects(): Promise<Project[]> {
  const resp = await apiFetch("/v1/projects");
  if (!resp.ok) throw new Error(`listProjects failed: ${resp.status}`);
  return resp.json();
}

export async function listArkServers(): Promise<{ server_id: string; base_url: string }[]> {
  const resp = await apiFetch("/v1/projects/servers");
  if (!resp.ok) return [];
  return resp.json();
}

export async function createProject(
  server: string,
  body: { name: string; description?: string; project_context?: string; root?: string },
): Promise<Project> {
  const resp = await apiFetch(`/v1/projects?server=${encodeURIComponent(server)}`, {
    method: "POST",
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(await resp.text());
  return resp.json();
}

export async function updateProject(
  projectId: string,
  server: string,
  body: { name?: string; description?: string; project_context?: string },
): Promise<Project> {
  const resp = await apiFetch(`/v1/projects/${projectId}?server=${encodeURIComponent(server)}`, {
    method: "PUT",
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(await resp.text());
  return resp.json();
}

export async function deleteProject(projectId: string, server: string): Promise<void> {
  const resp = await apiFetch(`/v1/projects/${projectId}?server=${encodeURIComponent(server)}`, {
    method: "DELETE",
  });
  if (!resp.ok && resp.status !== 204) throw new Error(await resp.text());
}

interface FsTarget { base: string; q: string }
function fsTarget(kind: "project" | "workspace", id: string, server?: string): FsTarget {
  if (kind === "project") {
    return { base: `/v1/projects/${id}/files`, q: server ? `?server=${encodeURIComponent(server)}` : "" };
  }
  return { base: `/v1/agents/${id}/workspace/files`, q: "" };
}

export async function listDir(
  kind: "project" | "workspace", id: string, path: string, server?: string,
): Promise<DirListing> {
  const t = fsTarget(kind, id, server);
  const suffix = path ? `/${path.replace(/^\/+/, "")}` : "";
  const resp = await apiFetch(`${t.base}${suffix}${t.q}`);
  if (!resp.ok) throw new Error(`listDir failed: ${resp.status}`);
  return resp.json();
}

export async function readFile(
  kind: "project" | "workspace", id: string, path: string, server?: string,
): Promise<Response> {
  const t = fsTarget(kind, id, server);
  const resp = await apiFetch(`${t.base}/${path.replace(/^\/+/, "")}${t.q}`);
  if (!resp.ok) throw new Error(`readFile failed: ${resp.status}`);
  return resp;
}

export type FileProbeKind = "text" | "image" | "pdf" | "binary";

export interface FileProbe {
  kind: FileProbeKind;
  content_type: string;
}

/** Cheap byte-level classification. Backend sniffs the first ~8KB via a
 *  Range request against ark, applies a git-style heuristic, and returns
 *  the kind. Use before opening a preview so we can bail on binary files
 *  without ever creating a tab. */
export async function probeFile(
  kind: "project" | "workspace", id: string, path: string, server?: string,
): Promise<FileProbe> {
  const t = fsTarget(kind, id, server);
  const suffix = `/${path.replace(/^\/+/, "")}`;
  // `op=probe` piggybacks the existing file URL; add it alongside any
  // pre-existing query string (e.g. `?server=...`).
  const q = t.q ? `${t.q}&op=probe` : "?op=probe";
  const resp = await apiFetch(`${t.base}${suffix}${q}`);
  if (!resp.ok) throw new Error(`probeFile failed: ${resp.status}`);
  return resp.json();
}

export async function writeFile(
  kind: "project" | "workspace", id: string, path: string, body: Blob | string,
  server?: string,
): Promise<void> {
  const t = fsTarget(kind, id, server);
  const resp = await apiFetch(`${t.base}/${path.replace(/^\/+/, "")}${t.q}`, {
    method: "PUT",
    body,
  });
  if (!resp.ok) throw new Error(await resp.text());
}

export async function deletePath(
  kind: "project" | "workspace", id: string, path: string, server?: string,
): Promise<void> {
  const t = fsTarget(kind, id, server);
  const resp = await apiFetch(`${t.base}/${path.replace(/^\/+/, "")}${t.q}`, {
    method: "DELETE",
  });
  if (!resp.ok && resp.status !== 204) throw new Error(await resp.text());
}

export async function mkdir(
  kind: "project" | "workspace", id: string, path: string, server?: string,
): Promise<void> {
  const t = fsTarget(kind, id, server);
  const sep = t.q ? "&" : "?";
  const resp = await apiFetch(`${t.base}/${path.replace(/^\/+/, "")}${t.q}${sep}op=mkdir`, {
    method: "POST",
  });
  if (!resp.ok) throw new Error(await resp.text());
}

export async function renamePath(
  kind: "project" | "workspace", id: string, path: string, to: string,
  server?: string,
): Promise<void> {
  const t = fsTarget(kind, id, server);
  const sep = t.q ? "&" : "?";
  const resp = await apiFetch(
    `${t.base}/${path.replace(/^\/+/, "")}${t.q}${sep}op=rename`,
    { method: "POST", body: JSON.stringify({ to: to.replace(/^\/+/, "") }) },
  );
  if (!resp.ok) throw new Error(await resp.text());
}

/** Triggers a browser download of the path. For files this fetches the
 * bytes directly; for directories the backend builds a zip
 * (`?op=zip`). Streams through a blob → synthetic `<a download>` because
 * the auth header can't ride a plain `<a href>`. */
export async function downloadPath(
  kind: "project" | "workspace", id: string, path: string,
  isDir: boolean, server?: string,
): Promise<void> {
  const t = fsTarget(kind, id, server);
  const cleaned = path.replace(/^\/+/, "");
  const url = isDir
    ? `${t.base}/${cleaned}${t.q}${t.q ? "&" : "?"}op=zip`
    : `${t.base}/${cleaned}${t.q}`;
  const resp = await apiFetch(url);
  if (!resp.ok) throw new Error(`download failed: ${resp.status}`);
  const blob = await resp.blob();
  const objectUrl = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = objectUrl;
  const basename = cleaned.split("/").pop() || "download";
  a.download = isDir ? `${basename}.zip` : basename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(objectUrl), 1500);
}

export async function createSession(
  agentId: string,
  projectId?: string,
  projectServerId?: string,
  name?: string,
): Promise<import("./types").Session> {
  const body: Record<string, string> = { agent_id: agentId };
  if (projectId) body.project_id = projectId;
  if (projectServerId) body.project_server_id = projectServerId;
  if (name && name.trim()) body.name = name.trim();
  const resp = await apiFetch("/v1/sessions", {
    method: "POST",
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(await resp.text());
  return resp.json();
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
