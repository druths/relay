import { useCallback, useEffect, useRef, useState } from "react";
import { readFile, writeFile } from "../api";
import type { FileChangeEvent } from "../hooks/useRelay";

type Kind = "project" | "workspace";

interface Props {
  kind: Kind;
  /** Project id for `project`, agent id for `workspace`. */
  targetId: string;
  path: string;
  server?: string;
  /** Used to detect disk-side changes to the file we're editing. */
  fileChanges: FileChangeEvent[];
  /** The scope value we should match against `fileChanges[*].scope`
   * (`project_id` for projects, ark `agent_name` for workspaces). */
  scope: string;
  /** Lifted up so the tab bar can show the dirty dot. */
  onDirtyChange: (dirty: boolean) => void;
}

const TEXT_EXT_ALLOWLIST = new Set([
  "txt", "md", "markdown", "json", "yaml", "yml", "toml", "ini", "cfg",
  "csv", "tsv", "log", "py", "js", "ts", "tsx", "jsx", "swift", "go",
  "rs", "rb", "java", "c", "h", "cpp", "hpp", "cs", "sh", "bash", "zsh",
  "css", "scss", "html", "xml", "sql", "env", "gitignore",
]);

const IMAGE_EXT_ALLOWLIST = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "ico",
]);

function _hasTextExt(path: string): boolean {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return TEXT_EXT_ALLOWLIST.has(ext);
}

function _hasImageExt(path: string): boolean {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return IMAGE_EXT_ALLOWLIST.has(ext);
}

export function FileEditorTab({
  kind, targetId, path, server, fileChanges, scope, onDirtyChange,
}: Props) {
  const [savedContent, setSavedContent] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [isBinary, setIsBinary] = useState(false);
  /** Object URL for an image preview. Revoked on path/type change. */
  const [imageUrl, setImageUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [staleBanner, setStaleBanner] = useState(false);
  /** True when the file isn't currently on disk — either it 404'd on load
   * or a delete event arrived. The tab stays open, the draft is kept, and
   * Save recreates the file. */
  const [notOnDisk, setNotOnDisk] = useState(false);

  const isDirty = savedContent !== null && draft !== savedContent;

  useEffect(() => {
    onDirtyChange(isDirty);
  }, [isDirty, onDirtyChange]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    setStaleBanner(false);
    // Revoke any stale image url before swapping in a new one.
    setImageUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return null; });
    try {
      const resp = await readFile(kind, targetId, path, server);
      const ct = resp.headers.get("content-type") ?? "";
      const isText = ct.startsWith("text/") || ct.includes("json") || ct.includes("xml") || _hasTextExt(path);
      const isImage = ct.startsWith("image/") || (!isText && _hasImageExt(path));
      if (isText) {
        const text = await resp.text();
        setSavedContent(text);
        setDraft(text);
        setIsBinary(false);
        setNotOnDisk(false);
      } else if (isImage) {
        const blob = await resp.blob();
        setImageUrl(URL.createObjectURL(blob));
        setIsBinary(false);
        setSavedContent(null);
        setNotOnDisk(false);
      } else {
        setIsBinary(true);
        setSavedContent(null);
        setNotOnDisk(false);
      }
    } catch (e) {
      // 404 → treat the tab as a "new file": empty saved state, user's
      // draft preserved if any. The next save recreates the file on disk.
      if (String(e).includes("404")) {
        setSavedContent("");
        setIsBinary(false);
        setNotOnDisk(true);
      } else {
        setError(String(e));
      }
    } finally {
      setLoading(false);
    }
  }, [kind, targetId, path, server]);

  // Clean up the blob url when the component unmounts so we don't leak.
  useEffect(() => () => {
    if (imageUrl) URL.revokeObjectURL(imageUrl);
  }, [imageUrl]);

  useEffect(() => {
    load();
  }, [load]);

  // Track which file-change events we've already reacted to so a single
  // disk change only triggers one stale-handling decision.
  const lastSeenTs = useRef(0);
  useEffect(() => {
    const matches = fileChanges
      .filter((e) =>
        e.kind === kind && e.scope === scope && e.path === path && e.ts > lastSeenTs.current,
      );
    if (matches.length === 0) return;
    lastSeenTs.current = Math.max(...matches.map((e) => e.ts));
    // If the *last* event for our path was a delete, transition to
    // not-on-disk regardless of dirty state — the user's draft survives
    // and Save will recreate the file. A later create/modify event will
    // route through the normal load path and clear the indicator.
    const last = matches[matches.length - 1];
    if (last.change === "deleted") {
      setSavedContent("");
      setNotOnDisk(true);
      setStaleBanner(false);
      return;
    }
    if (isDirty) {
      setStaleBanner(true);
    } else {
      // Quiet reload — the user is viewing, not editing.
      load();
    }
  }, [fileChanges, kind, scope, path, isDirty, load]);

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      await writeFile(kind, targetId, path, draft, server);
      setSavedContent(draft);
      setStaleBanner(false);
      setNotOnDisk(false);
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  const reload = async () => {
    if (isDirty && !window.confirm("Discard your edits and reload from disk?")) return;
    await load();
  };

  return (
    <div className="flex-1 min-h-0 flex flex-col bg-gray-950">
      <div className="flex items-center gap-3 px-4 py-2 border-b border-gray-800 text-xs">
        <span className="font-mono text-gray-400 truncate flex-1" title={path}>{path}</span>
        {!isBinary && !imageUrl && !loading && (
          <button
            onClick={save}
            disabled={!isDirty || saving}
            title={saving ? "Saving…" : "Save"}
            className="p-1.5 rounded text-emerald-300 hover:text-white hover:bg-emerald-700/40
                       disabled:text-gray-600 disabled:hover:bg-transparent transition-colors"
          >
            {saving ? <SpinnerIcon /> : <SaveIcon />}
          </button>
        )}
        <button
          onClick={reload}
          disabled={loading}
          title="Reload from disk"
          className="p-1.5 rounded text-gray-300 hover:text-white hover:bg-gray-800
                     disabled:opacity-50 transition-colors"
        >
          <RefreshIcon />
        </button>
      </div>

      {staleBanner && (
        <div className="flex items-center gap-3 px-4 py-2 bg-amber-900/30 border-b border-amber-800/60 text-xs text-amber-200">
          <span className="flex-1">File changed on disk while you were editing.</span>
          <button
            onClick={load}
            className="px-2 py-1 rounded bg-amber-700 hover:bg-amber-600 text-white"
          >
            Reload (discards changes)
          </button>
          <button
            onClick={() => setStaleBanner(false)}
            className="px-2 py-1 text-amber-200 hover:text-white"
          >
            Keep my changes
          </button>
        </div>
      )}

      {notOnDisk && !staleBanner && (
        <div className="px-4 py-2 bg-blue-900/20 border-b border-blue-800/40 text-xs text-blue-200">
          File doesn't exist on disk — save to create it.
        </div>
      )}

      {error && (
        <div className="px-4 py-2 text-xs text-red-400 border-b border-gray-800">{error}</div>
      )}

      <div className="flex-1 min-h-0 overflow-auto">
        {loading && (
          <div className="p-6 text-sm text-gray-500">Loading…</div>
        )}
        {!loading && imageUrl && (
          <div className="h-full flex items-center justify-center p-4 bg-[repeating-conic-gradient(#1f2937_0_25%,#0b1220_0_50%)] bg-[length:24px_24px]">
            <img
              src={imageUrl}
              alt={path}
              className="max-w-full max-h-full object-contain shadow-xl"
            />
          </div>
        )}
        {!loading && isBinary && (
          <div className="p-6 text-sm text-gray-500 italic">
            Binary file — open in the file browser to download.
          </div>
        )}
        {!loading && !isBinary && !imageUrl && savedContent !== null && (
          <textarea
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            spellCheck={false}
            className="w-full h-full p-4 bg-gray-950 text-gray-200 font-mono text-[13px]
                       leading-relaxed resize-none outline-none border-none"
          />
        )}
      </div>
    </div>
  );
}

// ── icons ────────────────────────────────────────────────────────────

function SaveIcon() {
  // Floppy disk silhouette — the universal "save" affordance.
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path d="M3 4a2 2 0 012-2h9.586a1 1 0 01.707.293l1.414 1.414A1 1 0 0117 4.414V16a2 2 0 01-2 2H5a2 2 0 01-2-2V4zm2 0v3h7V4H5zm0 6v6h10v-6H5z" />
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
