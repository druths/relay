import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { DirListing } from "../types";
import type { FileChangeEvent } from "../hooks/useRelay";
import {
  deletePath,
  downloadPath,
  listDir,
  mkdir,
  renamePath,
  writeFile,
} from "../api";

type Kind = "project" | "workspace";

interface Props {
  /** Always shown as the panel title. */
  agentId: string | null;
  agentName: string | null;
  /** The agent's name on the ark side (its `llm_model`, with any `ark:`
   * prefix stripped). This is the value ark uses for `agent_name` in its
   * `workspace_file_changed` events — Relay's display name (`agentName`)
   * may differ in case, so we keep them as separate concepts. */
  agentArkName: string | null;
  projectId: string | null;
  projectName: string | null;
  projectServerId: string | null;
  /** When true the Workspace tab is available — ark sessions only. */
  workspaceAvailable: boolean;
  /** File-change WS events relayed from `useRelay`. The panel filters by
   * the active tab's scope (project_id / agent_ark_name) to refresh
   * listings and feed the "Recent changes" list. */
  fileChanges: FileChangeEvent[];
  /** Called when the user clicks a file in the tree. The parent opens or
   * focuses a tab in the central pane — the panel itself no longer
   * renders an inline preview/editor. */
  onOpenFile: (kind: Kind, targetId: string, path: string, server?: string) => void;
  onClose: () => void;
}

export function FileBrowserPanel({
  agentId,
  agentName,
  agentArkName,
  projectId,
  projectName,
  projectServerId,
  workspaceAvailable,
  fileChanges,
  onOpenFile,
  onClose,
}: Props) {
  const projectTabAvailable = !!projectId;
  // Default to Project when bound; else Workspace.
  const [tab, setTab] = useState<Kind>(projectTabAvailable ? "project" : "workspace");

  // The tab automatically follows availability — useful when binding
  // changes (rare but happens on resume).
  useEffect(() => {
    if (tab === "project" && !projectTabAvailable) setTab("workspace");
    if (tab === "workspace" && !workspaceAvailable && projectTabAvailable) {
      setTab("project");
    }
  }, [projectTabAvailable, workspaceAvailable, tab]);

  return (
    <div
      className="h-full flex flex-col bg-gray-950 border-l border-gray-800 w-96"
      data-no-attach-drop="true"
    >
      <div className="flex items-center justify-between px-4 py-2 border-b border-gray-800">
        <div className="text-sm font-medium text-gray-300">Files</div>
        <button
          onClick={onClose}
          className="text-gray-500 hover:text-gray-300"
          title="Close panel"
        >
          ×
        </button>
      </div>

      {/* Tabs */}
      <div className="flex border-b border-gray-800 text-xs">
        {projectTabAvailable && (
          <TabButton
            active={tab === "project"}
            onClick={() => setTab("project")}
            label={`Project${projectName ? ` · ${projectName}` : ""}`}
          />
        )}
        {workspaceAvailable && (
          <TabButton
            active={tab === "workspace"}
            onClick={() => setTab("workspace")}
            label={`Workspace${agentName ? ` · ${agentName}` : ""}`}
          />
        )}
      </div>

      {/* Body */}
      <div className="flex-1 min-h-0 overflow-hidden">
        {tab === "project" && projectId && (
          <FileTreeView
            kind="project"
            id={projectId}
            scope={projectId}
            server={projectServerId ?? undefined}
            fileChanges={fileChanges}
            onOpenFile={onOpenFile}
          />
        )}
        {tab === "workspace" && agentId && agentName && (
          <FileTreeView
            kind="workspace"
            id={agentId}
            scope={agentArkName ?? agentName}
            onOpenFile={onOpenFile}
            fileChanges={fileChanges}
          />
        )}
      </div>
    </div>
  );
}

function TabButton({
  active, onClick, label,
}: { active: boolean; onClick: () => void; label: string }) {
  return (
    <button
      onClick={onClick}
      className={`px-3 py-2 truncate ${
        active
          ? "text-gray-100 border-b-2 border-blue-500"
          : "text-gray-500 hover:text-gray-300"
      }`}
      title={label}
    >
      {label}
    </button>
  );
}

// ── File tree view ────────────────────────────────────────────────────

function FileTreeView({
  kind, id, scope, server, fileChanges, onOpenFile,
}: {
  kind: Kind;
  id: string;
  scope: string;       // project_id or agent_name — used to filter file-change events
  server?: string;
  fileChanges: FileChangeEvent[];
  onOpenFile: (kind: Kind, targetId: string, path: string, server?: string) => void;
}) {
  const [root, setRoot] = useState<DirListing | null>(null);
  const [expanded, setExpanded] = useState<Map<string, DirListing>>(new Map());
  /// Path currently hovered as a drag-and-drop target ("" = root). Set
  /// by row-level onDragOver, cleared on drop / outer dragleave.
  const [dragOverPath, setDragOverPath] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const loadRoot = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const listing = await listDir(kind, id, "", server);
      setRoot(listing);
    } catch (e) {
      setError(String(e));
      setRoot(null);
    } finally {
      setLoading(false);
    }
  }, [kind, id, server]);

  const loadSubdir = useCallback(async (path: string) => {
    try {
      const listing = await listDir(kind, id, path, server);
      setExpanded((m) => {
        const next = new Map(m);
        next.set(path, listing);
        return next;
      });
    } catch (e) {
      setError(String(e));
    }
  }, [kind, id, server]);

  const collapseSubdir = useCallback((path: string) => {
    setExpanded((m) => {
      const next = new Map(m);
      next.delete(path);
      return next;
    });
  }, []);

  useEffect(() => {
    loadRoot();
    setExpanded(new Map());
  }, [loadRoot]);

  // Re-load on every matching live file-change event. Previously we only
  // refreshed the deepest open ancestor of the changed path — but when the
  // change happened in a directory that wasn't currently expanded (e.g.
  // the agent writing to a sibling subtree), nothing reloaded and the
  // panel stayed stale. Refresh root + every expanded subdir on any hit;
  // listings are cheap and ark coalesces bursts to ~200ms.
  const lastFileChangeTs = useRef(0);
  // `expanded` keys, captured fresh each render via a ref so the effect
  // can iterate them without re-running on every Map mutation.
  const expandedKeysRef = useRef<string[]>([]);
  expandedKeysRef.current = Array.from(expanded.keys());

  useEffect(() => {
    const recent = fileChanges.filter(
      (e) => e.kind === kind && e.scope === scope && e.ts > lastFileChangeTs.current,
    );
    if (recent.length === 0) return;
    lastFileChangeTs.current = Math.max(...recent.map((e) => e.ts));
    loadRoot();
    for (const dir of expandedKeysRef.current) {
      loadSubdir(dir);
    }
  }, [fileChanges, kind, scope, loadRoot, loadSubdir]);

  // ── actions ─────────────────────────────────────────────

  const handleUpload = async (files: FileList | null, targetDir: string) => {
    if (!files || files.length === 0) return;
    setUploading(true);
    setError(null);
    try {
      for (const f of Array.from(files)) {
        const path = targetDir ? `${targetDir}/${f.name}` : f.name;
        await writeFile(kind, id, path, f, server);
      }
      // Listings refresh via the WS event, but if ark misses the event for
      // some reason, force a reload. For a non-root target we always
      // loadSubdir — that also expands a previously-closed folder, so the
      // user sees what landed there instead of a silent success.
      if (!targetDir) await loadRoot();
      else await loadSubdir(targetDir);
    } catch (e) {
      setError(String(e));
    } finally {
      setUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  };

  /// Drop-target helpers, factored so every directory row + the root
  /// scroll area share the same behaviour. We stop event propagation so
  /// the deepest target wins (the row's onDragOver fires before the
  /// container's bubbled handler).
  const makeDropHandlers = (targetDir: string) => ({
    onDragOver: (e: React.DragEvent) => {
      if (!e.dataTransfer.types.includes("Files")) return;
      e.preventDefault();
      e.stopPropagation();
      e.dataTransfer.dropEffect = "copy";
      if (dragOverPath !== targetDir) setDragOverPath(targetDir);
    },
    onDrop: (e: React.DragEvent) => {
      if (!e.dataTransfer.types.includes("Files")) return;
      e.preventDefault();
      e.stopPropagation();
      setDragOverPath(null);
      void handleUpload(e.dataTransfer.files, targetDir);
    },
  });

  /// Outer container's leave handler — clears the highlight when the
  /// drag pointer leaves the panel entirely. Each child's dragenter
  /// will re-set it.
  const handleOuterDragLeave = (e: React.DragEvent) => {
    if (!e.dataTransfer.types.includes("Files")) return;
    // dragleave fires when entering child elements too. Only clear if
    // we've actually left the panel (relatedTarget is outside).
    const next = e.relatedTarget as Node | null;
    if (next && (e.currentTarget as Node).contains(next)) return;
    setDragOverPath(null);
  };

  const _refreshParent = (path: string) => {
    const parent = path.includes("/") ? path.split("/").slice(0, -1).join("/") : "";
    if (parent === "") loadRoot();
    else if (expanded.has(parent)) loadSubdir(parent);
  };

  const handleDelete = async (path: string) => {
    if (!confirm(`Delete ${path}?`)) return;
    try {
      await deletePath(kind, id, path, server);
      _refreshParent(path);
    } catch (e) {
      setError(String(e));
    }
  };

  const handleRename = async (path: string) => {
    const current = path.split("/").pop() ?? path;
    const next = prompt("Rename to:", current);
    if (!next || next === current) return;
    const cleaned = next.trim().replace(/^\/+/, "");
    if (!cleaned) return;
    // Resolve relative to the same parent dir as the source.
    const parent = path.includes("/") ? path.split("/").slice(0, -1).join("/") : "";
    const dst = parent ? `${parent}/${cleaned}` : cleaned;
    try {
      await renamePath(kind, id, path, dst, server);
      _refreshParent(path);
    } catch (e) {
      setError(String(e));
    }
  };

  const handleDownload = async (path: string, isDir: boolean) => {
    try {
      await downloadPath(kind, id, path, isDir, server);
    } catch (e) {
      setError(String(e));
    }
  };

  const handleMkdir = async () => {
    const name = prompt("New folder name:");
    if (!name) return;
    try {
      await mkdir(kind, id, name, server);
      loadRoot();
    } catch (e) {
      setError(String(e));
    }
  };

  /// Prompt for a filename and open a tab for it. The file isn't written
  /// to disk yet — the editor lands in the "not on disk — save to create"
  /// state, and the first save creates it. Matches the New folder
  /// affordance shape.
  const handleNewFile = () => {
    const name = prompt("New file path (relative to root):");
    if (!name) return;
    const cleaned = name.replace(/^\/+/, "").trim();
    if (!cleaned) return;
    onOpenFile(kind, id, cleaned, server);
  };

  // ── render ──────────────────────────────────────────────

  const recent = useMemo(
    () => fileChanges
      .filter((e) => e.kind === kind && e.scope === scope)
      .slice(-10)
      .reverse(),
    [fileChanges, kind, scope],
  );

  return (
    <div className="h-full flex flex-col">
      {/* Toolbar */}
      <div className="flex items-center gap-1 px-3 py-2 border-b border-gray-800">
        <ToolbarIcon
          onClick={() => fileInputRef.current?.click()}
          disabled={uploading}
          title={uploading ? "Uploading…" : "Upload files"}
        >
          {uploading ? <SpinnerIcon /> : <UploadIcon />}
        </ToolbarIcon>
        <ToolbarIcon onClick={handleNewFile} title="New file">
          <DocPlusIcon />
        </ToolbarIcon>
        <ToolbarIcon onClick={handleMkdir} title="New folder">
          <FolderPlusIcon />
        </ToolbarIcon>
        <ToolbarIcon onClick={loadRoot} title="Refresh">
          <RefreshIcon />
        </ToolbarIcon>
        <input
          ref={fileInputRef}
          type="file"
          multiple
          className="hidden"
          onChange={(e) => handleUpload(e.target.files, "")}
        />
      </div>

      {error && (
        <div className="px-3 py-1 text-xs text-red-400 border-b border-gray-800">{error}</div>
      )}

      <div
        className={`flex-1 min-h-0 overflow-y-auto py-1 relative transition-colors
                    ${dragOverPath === "" ? "bg-emerald-950/30" : ""}`}
        {...makeDropHandlers("")}
        onDragLeave={handleOuterDragLeave}
      >
        {loading && !root && <div className="text-xs text-gray-600 px-3 py-2">Loading…</div>}
        {root && (
          <DirView
            listing={root}
            path=""
            depth={0}
            expanded={expanded}
            loadSubdir={loadSubdir}
            collapseSubdir={collapseSubdir}
            onOpenFile={(p) => onOpenFile(kind, id, p, server)}
            onDelete={handleDelete}
            onRename={handleRename}
            onDownload={handleDownload}
            dragOverPath={dragOverPath}
            makeDropHandlers={makeDropHandlers}
          />
        )}
        {dragOverPath === "" && (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
            <div className="px-3 py-1.5 rounded-md bg-emerald-900/80 text-emerald-100
                            text-xs font-medium border border-emerald-700/60">
              Drop to upload to root
            </div>
          </div>
        )}
      </div>

      {/* Recent changes feed */}
      {recent.length > 0 && (
        <div className="border-t border-gray-800 text-xs">
          <div className="px-3 py-1 text-gray-500">Recent changes</div>
          <div className="max-h-32 overflow-y-auto">
            {recent.map((ev) => (
              <div
                key={`${ev.ts}-${ev.path}`}
                className="px-3 py-0.5 flex justify-between font-mono text-[11px] text-gray-400 hover:bg-gray-900"
              >
                <span className="truncate">
                  <span
                    className={
                      ev.change === "created"
                        ? "text-emerald-400"
                        : ev.change === "deleted"
                        ? "text-red-400"
                        : "text-amber-400"
                    }
                  >
                    {ev.change[0].toUpperCase()}
                  </span>{" "}
                  {ev.path}
                </span>
                <span className="text-gray-600">{_relativeTime(ev.ts)}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function DirView({
  listing, path, depth, expanded, loadSubdir, collapseSubdir,
  onOpenFile, onDelete, onRename, onDownload,
  dragOverPath, makeDropHandlers,
}: {
  listing: DirListing;
  path: string;
  depth: number;
  expanded: Map<string, DirListing>;
  loadSubdir: (p: string) => void;
  collapseSubdir: (p: string) => void;
  onOpenFile: (p: string) => void;
  onDelete: (p: string) => void;
  onRename: (p: string) => void;
  onDownload: (p: string, isDir: boolean) => void;
  dragOverPath: string | null;
  makeDropHandlers: (targetDir: string) => {
    onDragOver: (e: React.DragEvent) => void;
    onDrop: (e: React.DragEvent) => void;
  };
}) {
  return (
    <div>
      {listing.entries.map((entry) => {
        const childPath = path ? `${path}/${entry.name}` : entry.name;
        const isOpen = expanded.has(childPath);
        // Folders drop into themselves; files drop into their parent so
        // dragging onto a file uploads alongside it.
        const dropTarget = entry.is_dir ? childPath : path;
        const isDropActive = dragOverPath === dropTarget;
        return (
          <div key={entry.name}>
            <div
              {...makeDropHandlers(dropTarget)}
              className={`group flex items-center gap-1 px-2 py-0.5 text-xs cursor-pointer
                          text-gray-300 transition-colors
                          ${isDropActive
                            ? "bg-emerald-900/60 ring-1 ring-emerald-600/60 ring-inset"
                            : "hover:bg-gray-900"}`}
              style={{ paddingLeft: 8 + depth * 12 }}
              onClick={() => {
                if (entry.is_dir) {
                  if (isOpen) collapseSubdir(childPath);
                  else loadSubdir(childPath);
                } else {
                  onOpenFile(childPath);
                }
              }}
            >
              <span className="w-3 text-gray-600">
                {entry.is_dir ? (isOpen ? "▾" : "▸") : ""}
              </span>
              <span className="flex-1 truncate">
                {entry.is_dir ? "📁 " : "📄 "}
                {entry.name}
              </span>
              {!entry.is_dir && (
                <span className="text-gray-600">{_formatSize(entry.size)}</span>
              )}
              <RowMenu
                path={childPath}
                isDir={entry.is_dir}
                onRename={onRename}
                onDownload={onDownload}
                onDelete={onDelete}
              />
            </div>
            {entry.is_dir && isOpen && expanded.get(childPath) && (
              <DirView
                listing={expanded.get(childPath)!}
                path={childPath}
                depth={depth + 1}
                expanded={expanded}
                loadSubdir={loadSubdir}
                collapseSubdir={collapseSubdir}
                onOpenFile={onOpenFile}
                onDelete={onDelete}
                onRename={onRename}
                onDownload={onDownload}
                dragOverPath={dragOverPath}
                makeDropHandlers={makeDropHandlers}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}

/** Hover-visible kebab on each row that opens a tiny action menu.
 *  Earlier the row had a single × delete; we kept the same hover-show
 *  pattern but expanded to a dropdown with Rename / Download / Delete. */
function RowMenu({
  path, isDir, onRename, onDownload, onDelete,
}: {
  path: string;
  isDir: boolean;
  onRename: (p: string) => void;
  onDownload: (p: string, isDir: boolean) => void;
  onDelete: (p: string) => void;
}) {
  const [open, setOpen] = useState(false);
  // Close on any click anywhere else.
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    document.addEventListener("click", close);
    return () => document.removeEventListener("click", close);
  }, [open]);
  return (
    <span className="relative">
      <button
        onClick={(e) => {
          e.stopPropagation();
          setOpen((v) => !v);
        }}
        className="opacity-0 group-hover:opacity-100 text-gray-500 hover:text-gray-200 px-1"
        title="Actions"
      >
        <svg xmlns="http://www.w3.org/2000/svg" className="w-3.5 h-3.5" viewBox="0 0 16 16" fill="currentColor">
          <circle cx="8" cy="3" r="1.3" />
          <circle cx="8" cy="8" r="1.3" />
          <circle cx="8" cy="13" r="1.3" />
        </svg>
      </button>
      {open && (
        <div
          onClick={(e) => e.stopPropagation()}
          className="absolute right-0 top-5 z-40 w-36 py-1 rounded-md
                     bg-gray-900 border border-gray-700 shadow-xl text-gray-200"
        >
          <button
            onClick={() => { setOpen(false); onRename(path); }}
            className="block w-full text-left px-3 py-1 hover:bg-gray-800"
          >
            Rename…
          </button>
          <button
            onClick={() => { setOpen(false); onDownload(path, isDir); }}
            className="block w-full text-left px-3 py-1 hover:bg-gray-800"
          >
            {isDir ? "Download zip" : "Download"}
          </button>
          <button
            onClick={() => { setOpen(false); onDelete(path); }}
            className="block w-full text-left px-3 py-1 text-red-400 hover:bg-gray-800"
          >
            Delete
          </button>
        </div>
      )}
    </span>
  );
}


// ── helpers ──────────────────────────────────────────────────────────

function _formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}K`;
  return `${(bytes / 1024 / 1024).toFixed(1)}M`;
}

function _relativeTime(ts: number): string {
  const secs = Math.round((Date.now() - ts) / 1000);
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.round(secs / 60)}m`;
  if (secs < 86400) return `${Math.round(secs / 3600)}h`;
  return `${Math.round(secs / 86400)}d`;
}

// ── icons ────────────────────────────────────────────────────────────

function ToolbarIcon({
  children, onClick, disabled, title,
}: {
  children: React.ReactNode;
  onClick: () => void;
  disabled?: boolean;
  title: string;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      className="p-1.5 rounded text-gray-400 hover:text-white hover:bg-gray-800
                 disabled:opacity-50 disabled:hover:bg-transparent transition-colors"
    >
      {children}
    </button>
  );
}

function UploadIcon() {
  // Tray with an upward arrow leaving it.
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path d="M10 3a.75.75 0 01.75.75v6.69l1.97-1.97a.75.75 0 111.06 1.06l-3.25 3.25a.75.75 0 01-1.06 0L6.22 9.53a.75.75 0 011.06-1.06l1.97 1.97V3.75A.75.75 0 0110 3z" />
      <path d="M3.5 13a.75.75 0 011.5 0v2.25c0 .138.112.25.25.25h9.5a.25.25 0 00.25-.25V13a.75.75 0 011.5 0v2.25A1.75 1.75 0 0114.75 17h-9.5A1.75 1.75 0 013.5 15.25V13z" />
    </svg>
  );
}


function DocPlusIcon() {
  // Document with a "+" sigil — paired visually with FolderPlusIcon.
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path d="M5 3a2 2 0 012-2h5l4 4v12a2 2 0 01-2 2H7a2 2 0 01-2-2V3zm6 0v3a1 1 0 001 1h3" stroke="currentColor" strokeWidth="1" fill="none" />
      <path d="M10 9.5a.5.5 0 01.5.5v1.5H12a.5.5 0 010 1h-1.5V14a.5.5 0 01-1 0v-1.5H8a.5.5 0 010-1h1.5V10a.5.5 0 01.5-.5z" />
    </svg>
  );
}

function FolderPlusIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path d="M2 5a2 2 0 012-2h3.586a1 1 0 01.707.293l1.121 1.121A2 2 0 0010.828 5H16a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V5z" />
      <path d="M10 8.5a.5.5 0 01.5.5v1.5H12a.5.5 0 010 1h-1.5V13a.5.5 0 01-1 0v-1.5H8a.5.5 0 010-1h1.5V9a.5.5 0 01.5-.5z" fill="#0b0f19" />
    </svg>
  );
}

function RefreshIcon() {
  // Circular arrow.
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path
        fillRule="evenodd"
        d="M15.312 11.424a5.5 5.5 0 01-9.201 2.466l-.312-.311h2.433a.75.75 0 000-1.5H3.989a.75.75 0 00-.75.75v4.242a.75.75 0 001.5 0v-2.43l.31.31a7 7 0 0011.712-3.138.75.75 0 00-1.449-.39zm1.23-3.723a.75.75 0 00.219-.53V2.929a.75.75 0 00-1.5 0v2.43l-.31-.31A7 7 0 003.239 8.187a.75.75 0 101.448.389A5.5 5.5 0 0113.89 6.11l.311.31h-2.432a.75.75 0 000 1.5h4.243a.75.75 0 00.53-.219z"
        clipRule="evenodd"
      />
    </svg>
  );
}


function SpinnerIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor" className="animate-spin">
      <path
        fillRule="evenodd"
        d="M10 2a8 8 0 100 16 8 8 0 000-16zm0 2a6 6 0 110 12 6 6 0 010-12z"
        clipRule="evenodd"
        opacity="0.25"
      />
      <path d="M10 2a8 8 0 018 8h-2a6 6 0 00-6-6V2z" />
    </svg>
  );
}

