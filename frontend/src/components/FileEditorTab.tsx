import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import CodeMirror from "@uiw/react-codemirror";
import type { ReactCodeMirrorRef } from "@uiw/react-codemirror";
import { EditorView } from "@codemirror/view";
import { oneDark } from "@codemirror/theme-one-dark";
import { openSearchPanel } from "@codemirror/search";
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
  /** Identifier of the parent's tab entry — passed through to the
   * dirty-change callback so the parent can update the right row without
   * needing a per-tab arrow (which would break referential stability and
   * trigger a re-render loop through the effect below). */
  tabId: string;
  /** Lifted up so the tab bar can show the dirty dot. Signature takes
   * the tabId so a single stable useCallback can serve every open tab. */
  onDirtyChange: (tabId: string, dirty: boolean) => void;
}

const IMAGE_EXT_ALLOWLIST = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif",
  "ico", "svg", "avif",
]);

const PDF_EXT_ALLOWLIST = new Set(["pdf"]);

const TEXT_EXT_ALLOWLIST = new Set([
  "txt", "md", "markdown", "json", "yaml", "yml", "toml", "ini", "cfg",
  "csv", "tsv", "log", "py", "js", "ts", "tsx", "jsx", "swift", "go",
  "rs", "rb", "java", "c", "h", "cpp", "hpp", "cs", "sh", "bash", "zsh",
  "css", "scss", "html", "xml", "sql", "env", "gitignore",
]);

function _extOf(path: string): string {
  return path.split(".").pop()?.toLowerCase() ?? "";
}

function _hasTextExt(path: string): boolean {
  return TEXT_EXT_ALLOWLIST.has(_extOf(path));
}

function _hasImageExt(path: string): boolean {
  return IMAGE_EXT_ALLOWLIST.has(_extOf(path));
}

function _hasPdfExt(path: string): boolean {
  return PDF_EXT_ALLOWLIST.has(_extOf(path));
}

/** True when the file browser can preview this file in-app — used by the
 *  file browser to pick between "openable" and "binary" row icons. */
export function isPreviewableFile(path: string): boolean {
  return _hasTextExt(path) || _hasImageExt(path) || _hasPdfExt(path);
}

/** Extensions we're confident are binary — used for row icons so we don't
 *  falsely mark extensionless text like README/Dockerfile/Makefile as
 *  binary. Anything not on this list stays neutral in the browser row;
 *  the byte-level probe on click is what really decides. */
const KNOWN_BINARY_EXT = new Set([
  "exe", "dll", "so", "dylib", "class", "jar", "wasm", "o", "a", "lib",
  "bin", "dat", "iso",
  "zip", "tar", "tgz", "gz", "bz2", "xz", "7z", "rar",
  "mp3", "mp4", "mov", "mkv", "avi", "webm", "wav", "flac", "ogg", "m4a",
  "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
  "psd", "ai", "sketch", "fig",
  "ttf", "otf", "woff", "woff2", "eot",
]);

export function isKnownBinaryExt(path: string): boolean {
  return KNOWN_BINARY_EXT.has(_extOf(path));
}

export function FileEditorTab({
  kind, targetId, path, server, fileChanges, scope, tabId, onDirtyChange,
}: Props) {
  const [savedContent, setSavedContent] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [isBinary, setIsBinary] = useState(false);
  /** Object URL for an image preview. Revoked on path/type change. */
  const [imageUrl, setImageUrl] = useState<string | null>(null);
  /** Object URL for an inline PDF preview (rendered in an iframe). */
  const [pdfUrl, setPdfUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [staleBanner, setStaleBanner] = useState(false);
  /** True when the file isn't currently on disk — either it 404'd on load
   * or a delete event arrived. The tab stays open, the draft is kept, and
   * Save recreates the file. */
  const [notOnDisk, setNotOnDisk] = useState(false);
  /** Persisted global preference. CodeMirror handles per-row line numbers
   * in both modes natively, so the gutter stays visible either way.
   * Defaults to ON: most ark/project files are prose-like (markdown,
   * configs, drafts) where horizontal scrolling for unwrapped long lines
   * is more friction than wrapping. */
  const [wrap, setWrap] = useState<boolean>(() => {
    try {
      const stored = localStorage.getItem("relay_editor_wrap");
      return stored === null ? true : stored === "1";
    } catch { return true; }
  });
  useEffect(() => {
    try { localStorage.setItem("relay_editor_wrap", wrap ? "1" : "0"); }
    catch { /* ignore */ }
  }, [wrap]);

  // Handle to the CodeMirror instance so we can open the search panel
  // imperatively (from the toolbar magnifier button). The Cmd/Ctrl+F
  // keybinding is wired by CM's `searchKeymap` (included in basicSetup).
  const cmRef = useRef<ReactCodeMirrorRef | null>(null);

  const isDirty = savedContent !== null && draft !== savedContent;

  useEffect(() => {
    onDirtyChange(tabId, isDirty);
  }, [isDirty, tabId, onDirtyChange]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    setStaleBanner(false);
    // Revoke any stale blob urls before swapping in new ones.
    setImageUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return null; });
    setPdfUrl((prev) => { if (prev) URL.revokeObjectURL(prev); return null; });
    try {
      const resp = await readFile(kind, targetId, path, server);
      const ct = resp.headers.get("content-type") ?? "";
      const isText = ct.startsWith("text/") || ct.includes("json") || ct.includes("xml") || _hasTextExt(path);
      const isImage = ct.startsWith("image/") || (!isText && _hasImageExt(path));
      const isPdf = ct === "application/pdf" || (!isText && !isImage && _hasPdfExt(path));
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
      } else if (isPdf) {
        // Force the blob's MIME to application/pdf so the browser routes
        // it to its built-in PDF renderer inside the iframe. Some ark
        // paths serve PDFs as `application/octet-stream`.
        const raw = await resp.blob();
        const blob = raw.type === "application/pdf"
          ? raw
          : new Blob([raw], { type: "application/pdf" });
        setPdfUrl(URL.createObjectURL(blob));
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

  // Clean up blob urls when the component unmounts so we don't leak.
  useEffect(() => () => {
    if (imageUrl) URL.revokeObjectURL(imageUrl);
  }, [imageUrl]);
  useEffect(() => () => {
    if (pdfUrl) URL.revokeObjectURL(pdfUrl);
  }, [pdfUrl]);

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

  const openFind = () => {
    const view = cmRef.current?.view;
    if (view) openSearchPanel(view);
  };

  // Extensions list rebuilds only when `wrap` changes so CodeMirror
  // reconfigures line wrapping. Memoized so an unrelated parent re-render
  // (e.g. a WS event) doesn't hand CodeMirror a fresh array reference
  // every time and trigger a needless reconfigure. `oneDark` ships with
  // the line-number gutter styled.
  const extensions = useMemo(
    () => (wrap ? [oneDark, EditorView.lineWrapping] : [oneDark]),
    [wrap],
  );
  // Same reasoning — a stable object reference for `basicSetup` keeps
  // CodeMirror from re-processing its config on every parent re-render.
  const basicSetup = useMemo(
    () => ({
      lineNumbers: true,
      foldGutter: false,
      highlightActiveLine: false,
      highlightActiveLineGutter: false,
    }),
    [],
  );

  return (
    <div className="flex-1 min-h-0 min-w-0 flex flex-col bg-gray-950 relative">
      <div className="flex items-center gap-3 px-4 py-2 border-b border-gray-800 text-xs">
        <span className="font-mono text-gray-400 truncate flex-1" title={path}>{path}</span>
        {!isBinary && !imageUrl && !pdfUrl && !loading && (
          <button
            onClick={openFind}
            title="Find (⌘F)"
            className="p-1.5 rounded text-gray-300 hover:text-white hover:bg-gray-800 transition-colors"
          >
            <SearchIcon />
          </button>
        )}
        {!isBinary && !imageUrl && !pdfUrl && !loading && (
          <button
            onClick={() => setWrap((v) => !v)}
            title={wrap ? "Disable word wrap" : "Enable word wrap"}
            className={`p-1.5 rounded transition-colors ${
              wrap ? "text-blue-300 bg-blue-900/30 hover:bg-blue-900/40"
                   : "text-gray-300 hover:text-white hover:bg-gray-800"
            }`}
          >
            <WrapIcon />
          </button>
        )}
        {!isBinary && !imageUrl && !pdfUrl && !loading && (
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

      {/* `min-w-0` + `overflow-hidden` are load-bearing: without them, when
          wrap is off the `.cm-editor`'s intrinsic `min-width: max-content`
          (= width of the longest line) pushes this flex ancestor outward,
          which in turn balloons the whole pane. Constraining min-width
          and clipping overflow forces the horizontal scroll to happen
          inside `.cm-scroller` instead. */}
      <div className="flex-1 min-h-0 min-w-0 overflow-hidden">
        {loading && (
          <div className="p-6 text-sm text-gray-500">Loading…</div>
        )}
        {!loading && imageUrl && (
          <div className="h-full overflow-auto flex items-center justify-center p-4 bg-[repeating-conic-gradient(#1f2937_0_25%,#0b1220_0_50%)] bg-[length:24px_24px]">
            <img
              src={imageUrl}
              alt={path}
              className="max-w-full max-h-full object-contain shadow-xl"
            />
          </div>
        )}
        {!loading && pdfUrl && (
          <iframe
            src={pdfUrl}
            title={path}
            className="w-full h-full border-0 bg-white"
          />
        )}
        {!loading && isBinary && (
          <div className="p-6 text-sm text-gray-500 italic">
            Binary file — open in the file browser to download.
          </div>
        )}
        {!loading && !isBinary && !imageUrl && !pdfUrl && savedContent !== null && (
          <CodeMirror
            ref={cmRef}
            value={draft}
            onChange={(v) => setDraft(v)}
            extensions={extensions}
            height="100%"
            width="100%"
            theme={oneDark}
            basicSetup={basicSetup}
            className="h-full w-full text-[13px]"
          />
        )}
      </div>
    </div>
  );
}

// ── icons ────────────────────────────────────────────────────────────

function SearchIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path
        fillRule="evenodd"
        d="M9 3.5a5.5 5.5 0 100 11 5.5 5.5 0 000-11zM2 9a7 7 0 1112.452 4.391l3.328 3.329a.75.75 0 11-1.06 1.06l-3.329-3.328A7 7 0 012 9z"
        clipRule="evenodd"
      />
    </svg>
  );
}

function WrapIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path fillRule="evenodd"
        d="M3 4.75A.75.75 0 013.75 4h12.5a.75.75 0 010 1.5H3.75A.75.75 0 013 4.75zM3 14.75a.75.75 0 01.75-.75h6a.75.75 0 010 1.5h-6a.75.75 0 01-.75-.75zM3 9.75A.75.75 0 013.75 9h10c2.07 0 3 1.5 3 3s-.93 3-3 3h-1.94l.97.97a.75.75 0 11-1.06 1.06l-2.25-2.25a.75.75 0 010-1.06l2.25-2.25a.75.75 0 011.06 1.06l-.97.97h1.94c1.13 0 1.5-.75 1.5-1.5s-.37-1.5-1.5-1.5h-10A.75.75 0 013 9.75z"
        clipRule="evenodd" />
    </svg>
  );
}

function SaveIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
      <path d="M3 4a2 2 0 012-2h9.586a1 1 0 01.707.293l1.414 1.414A1 1 0 0117 4.414V16a2 2 0 01-2 2H5a2 2 0 01-2-2V4zm2 0v3h7V4H5zm0 6v6h10v-6H5z" />
    </svg>
  );
}

function RefreshIcon() {
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
