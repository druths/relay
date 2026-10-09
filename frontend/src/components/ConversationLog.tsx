import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import type { Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Message, FileAttachment } from "../types";
import { apiFetch } from "../api";
import { isPreviewableFile } from "./FileEditorTab";

/// GitHub-flavoured markdown plugin list. Adds table support (the
/// motivating feature — agent output often includes tables), plus
/// strikethrough and task lists for free. Kept as a module-level
/// constant so react-markdown doesn't rebuild its pipeline on each
/// render.
const REMARK_PLUGINS = [remarkGfm];

// Element overrides keep markdown output sized for chat bubbles: heading
// levels collapse to slightly-bigger weights, code blocks pick up the dark
// inline-code look, links open in a new tab. Same scope as iOS's
// `MarkdownText` (headings, fenced code, bold/italic, inline code) so the
// two clients stay in rough parity.
const MARKDOWN_COMPONENTS: Components = {
  p: ({ children }) => <p className="my-1 whitespace-pre-wrap">{children}</p>,
  h1: ({ children }) => <h1 className="text-base font-semibold mt-2 mb-1">{children}</h1>,
  h2: ({ children }) => <h2 className="text-sm font-semibold mt-2 mb-1">{children}</h2>,
  h3: ({ children }) => <h3 className="text-sm font-semibold mt-1.5 mb-0.5">{children}</h3>,
  h4: ({ children }) => <h4 className="text-sm font-semibold mt-1 mb-0.5">{children}</h4>,
  h5: ({ children }) => <h5 className="text-sm font-medium mt-1 mb-0.5">{children}</h5>,
  h6: ({ children }) => <h6 className="text-sm font-medium mt-1 mb-0.5">{children}</h6>,
  ul: ({ children }) => <ul className="list-disc ml-5 my-1 space-y-0.5">{children}</ul>,
  ol: ({ children }) => <ol className="list-decimal ml-5 my-1 space-y-0.5">{children}</ol>,
  li: ({ children }) => <li>{children}</li>,
  a: ({ children, href }) => (
    <a href={href} target="_blank" rel="noreferrer noopener" className="text-blue-300 underline hover:text-blue-200">
      {children}
    </a>
  ),
  blockquote: ({ children }) => (
    <blockquote className="border-l-2 border-gray-600 pl-2 my-1 italic text-gray-400">{children}</blockquote>
  ),
  code: ({ className, children, ...props }) => {
    // react-markdown gives code blocks a `language-*` class; inline code has none.
    const isBlock = (className ?? "").includes("language-");
    if (isBlock) {
      return (
        <pre className="bg-gray-900/70 border border-gray-800 rounded p-2 my-1 overflow-x-auto text-[12px] leading-snug">
          <code {...props}>{children}</code>
        </pre>
      );
    }
    return (
      <code className="bg-gray-900/70 rounded px-1 py-0.5 text-[12px]" {...props}>
        {children}
      </code>
    );
  },
  pre: ({ children }) => <>{children}</>,
  // GFM tables — dark-theme styled and horizontally scrollable so a
  // wide table doesn't blow out the chat bubble width.
  table: ({ children }) => (
    <div className="my-2 -mx-1 overflow-x-auto">
      <table className="min-w-full border-collapse border border-gray-700 text-[12px]">
        {children}
      </table>
    </div>
  ),
  thead: ({ children }) => (
    <thead className="bg-gray-900/70">{children}</thead>
  ),
  tbody: ({ children }) => <tbody>{children}</tbody>,
  tr: ({ children }) => (
    <tr className="border-t border-gray-800 first:border-t-0">{children}</tr>
  ),
  th: ({ children, style }) => (
    <th
      className="border border-gray-700 px-2 py-1 text-left font-semibold text-gray-200"
      style={style}
    >
      {children}
    </th>
  ),
  td: ({ children, style }) => (
    <td
      className="border border-gray-800 px-2 py-1 text-gray-300 align-top"
      style={style}
    >
      {children}
    </td>
  ),
};

function _formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

// ── Attachment preview dispatch ────────────────────────────────────
//
// Mirrors the iOS/Catalyst `AttachmentPreview` view. For images and
// text-ish files we render an inline preview above the pill-style
// caption; for anything else we fall through to the legacy pill
// unchanged.

const _TEXT_PREVIEW_EXTS = new Set<string>([
  "txt", "md", "markdown", "py", "js", "jsx", "ts", "tsx",
  "swift", "json", "yaml", "yml", "toml", "html", "htm", "css",
  "sh", "zsh", "sql", "csv", "log", "ini", "cfg", "conf",
  "rb", "go", "rs", "c", "h", "cpp", "hpp", "java", "kt",
  "xml", "env", "gitignore",
]);

type _AttachmentKind = "image" | "text" | "other";

function _attachmentKind(att: FileAttachment): _AttachmentKind {
  if (att.mime_type?.startsWith("image/")) return "image";
  if (att.mime_type?.startsWith("text/")) return "text";
  const ext = att.filename.split(".").pop()?.toLowerCase() ?? "";
  if (ext && _TEXT_PREVIEW_EXTS.has(ext)) return "text";
  return "other";
}

/** Dispatches on type. Image → inline thumbnail; text → first
 *  ~1500 chars; other → the legacy pill. */
function AttachmentPreview({
  attachment,
  onOpen,
}: {
  attachment: FileAttachment;
  onOpen?: (att: FileAttachment) => void;
}) {
  const kind = _attachmentKind(attachment);
  if (kind === "image") {
    return <ImageAttachmentPreview attachment={attachment} onOpen={onOpen} />;
  }
  if (kind === "text") {
    return <TextAttachmentPreview attachment={attachment} onOpen={onOpen} />;
  }
  return <AttachmentPill attachment={attachment} onOpen={onOpen} />;
}

/** Image attachment: fetches the bytes via auth'd `apiFetch`, builds
 *  a blob URL, renders inline capped at 360×240px. Click opens the
 *  image in a new tab (via the same download helper's blob URL so
 *  the browser treats it as an inline preview). Browser's native
 *  right-click menu covers "Save image as…" for free. */
function ImageAttachmentPreview({
  attachment,
  onOpen,
}: {
  attachment: FileAttachment;
  onOpen?: (att: FileAttachment) => void;
}) {
  const [src, setSrc] = useState<string | null>(null);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let revoked = false;
    let obj: string | null = null;
    (async () => {
      try {
        const resp = await apiFetch(attachment.url);
        if (!resp.ok) {
          setErr(true);
          return;
        }
        const blob = await resp.blob();
        if (revoked) return;
        obj = URL.createObjectURL(blob);
        setSrc(obj);
      } catch {
        setErr(true);
      }
    })();
    return () => {
      revoked = true;
      if (obj) URL.revokeObjectURL(obj);
    };
  }, [attachment.url]);

  return (
    <div className="inline-flex flex-col items-start gap-1">
      {src ? (
        <img
          src={src}
          alt={attachment.filename}
          className="max-w-[360px] max-h-[240px] object-contain rounded border border-gray-700 cursor-pointer"
          onClick={() => _downloadAttachment(attachment)}
          title="Click to download · right-click for more"
        />
      ) : err ? (
        <div className="w-60 h-40 flex items-center justify-center text-xs text-gray-500 bg-gray-900/40 rounded border border-gray-700">
          Couldn't load image
        </div>
      ) : (
        <div className="w-60 h-40 flex items-center justify-center text-xs text-gray-500 bg-gray-900/40 rounded border border-gray-700">
          Loading…
        </div>
      )}
      <AttachmentPill attachment={attachment} onOpen={onOpen} />
    </div>
  );
}

/** Text attachment: fetches the bytes, decodes as UTF-8, shows the
 *  first ~1500 chars / 20 lines in a monospace box with a fade
 *  gradient on truncation. */
function TextAttachmentPreview({
  attachment,
  onOpen,
}: {
  attachment: FileAttachment;
  onOpen?: (att: FileAttachment) => void;
}) {
  const [preview, setPreview] = useState<string | null>(null);
  const [truncated, setTruncated] = useState(false);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const resp = await apiFetch(attachment.url);
        if (!resp.ok) {
          setErr(true);
          return;
        }
        const text = await resp.text();
        if (cancelled) return;
        const { snippet, wasTruncated } = _truncatePreview(text);
        setPreview(snippet);
        setTruncated(wasTruncated);
      } catch {
        setErr(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [attachment.url]);

  const canOpen =
    !!onOpen && !!attachment.kind && !!attachment.path;
  const handleTap = () => {
    if (canOpen && onOpen) onOpen(attachment);
    else _downloadAttachment(attachment);
  };

  return (
    <div className="inline-flex flex-col items-start gap-1 max-w-[480px]">
      {preview != null ? (
        <div className="relative w-full">
          <pre
            onClick={handleTap}
            className="font-mono text-[11px] leading-relaxed text-gray-300 bg-gray-900/60 rounded border border-gray-700 p-3 max-w-[480px] whitespace-pre-wrap break-words cursor-pointer m-0 overflow-hidden"
          >{preview}</pre>
          {truncated && (
            <div
              className="absolute bottom-0 left-0 right-0 h-6 rounded-b pointer-events-none"
              style={{
                background: "linear-gradient(to bottom, rgba(17,24,39,0) 0%, rgba(17,24,39,0.95) 100%)",
              }}
            />
          )}
        </div>
      ) : err ? (
        <div className="w-60 h-16 flex items-center justify-center text-xs text-gray-500 bg-gray-900/40 rounded border border-gray-700">
          Couldn't load preview
        </div>
      ) : (
        <div className="w-60 h-20 flex items-center justify-center text-xs text-gray-500 bg-gray-900/40 rounded border border-gray-700">
          Loading…
        </div>
      )}
      <AttachmentPill attachment={attachment} onOpen={onOpen} />
    </div>
  );
}

const _PREVIEW_MAX_CHARS = 1500;
const _PREVIEW_MAX_LINES = 20;

function _truncatePreview(s: string): { snippet: string; wasTruncated: boolean } {
  const lines: string[] = [];
  let chars = 0;
  let wasTruncated = false;
  const srcLines = s.split("\n");
  for (const line of srcLines) {
    if (lines.length >= _PREVIEW_MAX_LINES) {
      wasTruncated = true;
      break;
    }
    if (chars + line.length > _PREVIEW_MAX_CHARS) {
      const remaining = _PREVIEW_MAX_CHARS - chars;
      if (remaining > 0) lines.push(line.slice(0, remaining));
      wasTruncated = true;
      break;
    }
    lines.push(line);
    chars += line.length + 1;
  }
  // Also flag truncation when the source had more lines than we read
  // (e.g. we hit the line cap before the char cap).
  if (!wasTruncated && srcLines.length > lines.length) wasTruncated = true;
  return { snippet: lines.join("\n"), wasTruncated };
}

async function _downloadAttachment(att: FileAttachment) {
  // The download endpoint requires the bearer token, which can't be attached
  // to a plain <a href>. Fetch as Blob and trigger a synthetic click.
  try {
    const resp = await apiFetch(att.url);
    if (!resp.ok) {
      console.error("Download failed", resp.status, await resp.text());
      return;
    }
    const blob = await resp.blob();
    const objectUrl = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = objectUrl;
    a.download = att.filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    // Revoke a bit later — Safari needs the URL to stay alive until the
    // download starts.
    setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
  } catch (err) {
    console.error("Download error", err);
  }
}

interface ConversationLogProps {
  lobbyMessages: Message[];
  sessionMessages: Message[];
  activeSessionId: string | null;
  activeAgentName: string | null;
  diagnostics?: boolean;
  /** Called when a user taps an agent-shared attachment that carries a
   *  workspace/project reference. Parent resolves the ark scope to a
   *  Relay agent + ark base_url and opens a `FileEditorTab`. When
   *  omitted, or the attachment lacks a ref, or the extension isn't
   *  openable, tap falls back to a plain download. */
  onOpenAttachment?: (att: FileAttachment) => void;
}

const ROLE_STYLES: Record<string, string> = {
  user: "bg-gray-800 ml-auto w-fit max-w-[calc(100%-3rem)] msg-user",
  operator: "bg-blue-900/40 w-fit max-w-[calc(100%-3rem)] msg-operator",
  agent: "bg-emerald-900/40 w-fit max-w-[calc(100%-3rem)] msg-agent",
};

function _formatTime(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  // 24h time with seconds, locale-aware date when the message isn't today.
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  const time = d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  return sameDay ? time : `${d.toLocaleDateString()} ${time}`;
}

function _formatPercent(used: number, total: number): string {
  const pct = total > 0 ? (used / total) * 100 : 0;
  return pct >= 10 ? `${pct.toFixed(0)}%` : `${pct.toFixed(1)}%`;
}


export function ConversationLog({
  lobbyMessages,
  sessionMessages,
  activeSessionId,
  activeAgentName,
  diagnostics = false,
  onOpenAttachment,
}: ConversationLogProps) {
  const endRef = useRef<HTMLDivElement>(null);
  const messages = activeSessionId ? sessionMessages : lobbyMessages;

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  if (messages.length === 0) {
    return (
      <div className="flex-1 flex items-center justify-center text-gray-600 text-sm">
        {activeSessionId
          ? `In session with ${activeAgentName ?? "agent"}. Loading…`
          : "Connect to start a conversation."}
      </div>
    );
  }

  return (
    <div className="flex-1 overflow-y-auto space-y-3 p-4">
      {messages.map((msg, i) => {
        if (msg.role === "compaction") {
          return <CompactionDivider key={i} msg={msg} />;
        }
        if (msg.role === "project_change") {
          return <ProjectChangeDivider key={i} msg={msg} />;
        }
        if (msg.role === "error") {
          return <ErrorDivider key={i} msg={msg} />;
        }
        if (msg.role === "date_marker") {
          return <DateMarkerDivider key={i} msg={msg} />;
        }
        const usage = msg.metadata?.usage;
        const totalTokens =
          (usage?.input_tokens ?? 0) + (usage?.output_tokens ?? 0);
        const showUsage =
          diagnostics && msg.role === "agent" && usage && totalTokens > 0;
        const showTime = diagnostics && !!msg.created_at;
        const isRight = msg.role === "user";
        const isAgent = msg.role === "agent";
        // Header rule: only appear when this message's source agent
        // differs from the previous message's. That means:
        //  - Two normal turns from the same agent → nothing (both
        //    have `metadata.speaker` unset → equal → no header).
        //  - A cross-agent injected message landing next to normal
        //    turns → header shows the source agent name.
        //  - Two injected messages from the same other agent → no
        //    header on the second one.
        // For the common single-agent session this means the pane is
        // just flowing text — no separators at all.
        const prev = messages[i - 1];
        const speakerOf = (m: typeof msg | undefined) =>
          m?.role === "agent" ? (m.metadata?.speaker ?? null) : undefined;
        const showAgentHeader =
          isAgent
          && speakerOf(msg) !== undefined  // always true for agent, kept for symmetry
          && !!msg.metadata?.speaker      // only inject-source messages get a header
          && speakerOf(prev) !== speakerOf(msg);
        return (
        <div key={i}>
        {showAgentHeader && (
          <div className="mt-2 mb-1 flex items-center gap-2 text-[10px] font-mono text-gray-500 uppercase tracking-wider">
            <span>{msg.metadata?.speaker ?? activeAgentName ?? "Agent"}</span>
            {msg.created_at && (
              <>
                <span className="text-gray-700">·</span>
                <span>{_formatTime(msg.created_at)}</span>
              </>
            )}
            <span className="flex-1 h-px bg-gray-800/70" />
          </div>
        )}
        <div
          className={
            isAgent
              // Agent contributions flow into the pane as plain
              // markdown — no bubble, no rounded corners, no
              // width constraint. Long-form output (code, tables,
              // lists) was fighting the bubble's padding jail.
              ? "text-sm msg-agent"
              : `rounded-lg px-4 py-3 text-sm ${
                  ROLE_STYLES[msg.role] || ROLE_STYLES.agent
                }`
          }
        >
          <div className={msg.role === "user" || msg.streaming ? "whitespace-pre-wrap" : "msg-md"}>
            {/* User messages and in-flight streaming text stay literal:
                user input shouldn't be parsed as markup, and partially
                streamed markdown (unclosed code fences, half-rendered
                headers) looks worse than the raw text. Once the turn is
                done we re-render through `ReactMarkdown`. */}
            {msg.role === "user" || msg.streaming ? (
              msg.text_content
            ) : (
              <ReactMarkdown components={MARKDOWN_COMPONENTS} remarkPlugins={REMARK_PLUGINS}>
                {msg.text_content}
              </ReactMarkdown>
            )}
            {msg.attachments && msg.attachments.length > 0 && (
              <div className={`flex flex-col gap-2 ${msg.text_content ? "mt-2" : ""}`}>
                {msg.attachments.map((att, ai) => (
                  <AttachmentPreview
                    key={ai}
                    attachment={att}
                    onOpen={onOpenAttachment}
                  />
                ))}
              </div>
            )}
            {msg.streaming && (
              <span className="inline-flex items-end gap-0.5 ml-1.5 mb-0.5">
                {[0, 1, 2].map((i) => (
                  <span
                    key={i}
                    className="block w-1.5 h-1.5 rounded-full bg-gray-400"
                    style={{
                      animation: "dotPulse 0.9s ease-in-out infinite",
                      animationDelay: `${i * 0.15}s`,
                    }}
                  />
                ))}
              </span>
            )}
            {msg.interrupted && (
              <span className="inline-flex items-center ml-1.5 opacity-40" title="interrupted">
                <svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor" className="text-gray-400">
                  <path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1ZM2 8a6 6 0 1 1 12 0A6 6 0 0 1 2 8Zm8.78-2.78a.75.75 0 0 0-1.06 0L8 6.94 6.28 5.22a.75.75 0 0 0-1.06 1.06L6.94 8l-1.72 1.72a.75.75 0 1 0 1.06 1.06L8 9.06l1.72 1.72a.75.75 0 1 0 1.06-1.06L9.06 8l1.72-1.72a.75.75 0 0 0 0-1.06Z"/>
                </svg>
              </span>
            )}
          </div>
        </div>
        {(showTime || showUsage) && (
          <div
            className={`mt-1 text-[10px] font-mono text-gray-500 flex flex-wrap gap-x-3 gap-y-0.5 ${
              isRight ? "justify-end ml-12" : "mr-12"
            }`}
          >
            {showTime && <span>{_formatTime(msg.created_at!)}</span>}
            {showUsage && (
              <span>
                {usage!.input_tokens ?? 0} in / {usage!.output_tokens ?? 0} out
                {usage!.context_window ? (
                  <>
                    {" · "}
                    {totalTokens.toLocaleString()} / {usage!.context_window.toLocaleString()} (
                    {_formatPercent(totalTokens, usage!.context_window)})
                  </>
                ) : null}
                {usage!.model ? <> · {usage!.model}</> : null}
              </span>
            )}
          </div>
        )}
        </div>
        );
      })}
      <div ref={endRef} />
    </div>
  );
}

// ── Compaction divider ───────────────────────────────────────────────

/** Renders the "Session compacted" marker inline in the transcript.
 *  A full-width divider with a chip label; the summary body is
 *  collapsed by default and revealed on click. Older messages above
 *  are NOT collapsed — the user can still scroll back through them. */
function CompactionDivider({ msg }: { msg: Message }) {
  const [expanded, setExpanded] = useState(false);
  const reason = msg.metadata?.reason ?? "";
  const label = _compactionReasonLabel(reason);
  return (
    <div className="my-4 flex items-center gap-3 px-1">
      <div className="flex-1 border-t border-amber-800/50" />
      <div className="flex flex-col items-center gap-1 max-w-[80%]">
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          className="inline-flex items-center gap-2 px-2.5 py-1 rounded-full
                     bg-amber-950/60 border border-amber-800/60 text-[11px]
                     font-mono text-amber-200 hover:bg-amber-900/60 transition-colors"
          title="Toggle summary"
        >
          <svg viewBox="0 0 16 16" width="10" height="10" fill="currentColor" aria-hidden>
            <path d="M2 4h12v1H2zM2 8h12v1H2zM2 12h8v1H2z"/>
          </svg>
          <span>Session compacted{label ? ` — ${label}` : ""}</span>
          <span className="text-amber-500">{expanded ? "▾" : "▸"}</span>
        </button>
        {expanded && msg.text_content && (
          <div className="text-[11px] text-amber-100/80 bg-amber-950/40 border border-amber-900/40
                          rounded-md px-3 py-2 max-h-64 overflow-y-auto whitespace-pre-wrap">
            {msg.text_content}
          </div>
        )}
      </div>
      <div className="flex-1 border-t border-amber-800/50" />
    </div>
  );
}

// ── Attachment pill ─────────────────────────────────────────────────

/** Renders a file attachment as a compact chip with two hit targets:
 *
 *  - The pill body: tap opens the file in an editor/viewer tab when the
 *    attachment carries a workspace/project ref and its extension is
 *    editor-openable. For binary attachments or attachments without a
 *    ref, tap falls back to a plain download (same single-action
 *    behavior as before this change).
 *  - The trailing kebab (⋮): opens a small popover with a Download
 *    item. Only rendered when the pill body would open — otherwise the
 *    single tap already downloads and a kebab would be noise.
 *
 *  Openability is classified by `isPreviewableFile` (the same list the
 *  file browser uses). Content-type mismatch is handled inside the
 *  editor tab, which will show "binary file — download" for anything
 *  it can't render. */
function AttachmentPill({
  attachment,
  onOpen,
}: {
  attachment: FileAttachment;
  onOpen?: (att: FileAttachment) => void;
}) {
  const canOpen =
    !!onOpen
    && !!attachment.kind
    && !!attachment.path
    && isPreviewableFile(attachment.path);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!menuOpen) return;
    const close = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpen(false);
      }
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [menuOpen]);

  const handleOpenClick = () => {
    if (canOpen && onOpen) onOpen(attachment);
    else _downloadAttachment(attachment);
  };

  return (
    // No `overflow-hidden` here on purpose — the kebab's dropdown is
    // positioned below the pill via `top-full` and would get clipped
    // by an overflow-hidden wrapper. Rounding is applied to the two
    // inner buttons individually instead so the pill still reads as a
    // single chip.
    <div className="inline-flex items-stretch self-start rounded border border-gray-700 text-xs text-gray-200">
      <button
        type="button"
        onClick={handleOpenClick}
        title={canOpen ? "Open" : "Download"}
        className={`inline-flex items-center gap-2 px-2 py-1 bg-gray-900/60 hover:bg-gray-900 rounded-l ${canOpen ? "" : "rounded-r"}`}
      >
        <svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor" className="text-gray-400">
          <path d="M9.5 0a.5.5 0 0 1 .5.5V3h2.5a.5.5 0 0 1 .5.5v11a.5.5 0 0 1-.5.5h-9a.5.5 0 0 1-.5-.5v-11a.5.5 0 0 1 .5-.5H6V.5a.5.5 0 0 1 .5-.5h3ZM4 4v10h8V4H4Z"/>
        </svg>
        <span className="truncate max-w-[20rem]">{attachment.filename}</span>
        {attachment.size_bytes > 0 && (
          <span className="text-gray-500">({_formatSize(attachment.size_bytes)})</span>
        )}
      </button>
      {canOpen && (
        <div className="relative flex" ref={menuRef}>
          <button
            type="button"
            onClick={() => setMenuOpen((v) => !v)}
            title="More actions"
            aria-label="More actions"
            className="px-1.5 border-l border-gray-700 bg-gray-900/60 hover:bg-gray-900 text-gray-400 hover:text-gray-200 flex items-center rounded-r"
          >
            <svg xmlns="http://www.w3.org/2000/svg" className="w-3.5 h-3.5" viewBox="0 0 16 16" fill="currentColor">
              <circle cx="8" cy="3" r="1.5" />
              <circle cx="8" cy="8" r="1.5" />
              <circle cx="8" cy="13" r="1.5" />
            </svg>
          </button>
          {menuOpen && (
            <div className="absolute right-0 top-full mt-1 z-[300] bg-gray-800 border border-gray-700 rounded-md shadow-xl py-1 min-w-[120px]">
              {/* Open is the pill's default tap action but we mirror it
                  in the menu so both actions are discoverable in one
                  place — matches what folks expect from a "…" menu. */}
              <button
                type="button"
                onClick={() => {
                  if (onOpen) onOpen(attachment);
                  setMenuOpen(false);
                }}
                className="w-full text-left px-3 py-1.5 text-xs text-gray-200 hover:bg-gray-700"
              >
                Open
              </button>
              <button
                type="button"
                onClick={() => {
                  _downloadAttachment(attachment);
                  setMenuOpen(false);
                }}
                className="w-full text-left px-3 py-1.5 text-xs text-gray-200 hover:bg-gray-700"
              >
                Download
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Error divider ────────────────────────────────────────────────────

/** Renders a `role: "error"` marker as a full-width divider with an
 *  expandable message body. Red-tinted so a dead turn reads as visibly
 *  distinct from compaction (amber) or project change (blue) at a
 *  glance. The chip shows the classified `code` (context_too_long,
 *  rate_limit, auth, token_budget_exceeded, other); the raw message
 *  reveals on click for cases where the provider's text matters. */
function ErrorDivider({ msg }: { msg: Message }) {
  const [expanded, setExpanded] = useState(false);
  const code = msg.metadata?.code ?? "error";
  const message = msg.metadata?.message ?? "";
  const label = _errorCodeLabel(code);
  return (
    <div className="my-4 flex items-center gap-3 px-1">
      <div className="flex-1 border-t border-red-800/50" />
      <div className="flex flex-col items-center gap-1 max-w-[80%]">
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          disabled={!message}
          className="inline-flex items-center gap-2 px-2.5 py-1 rounded-full
                     bg-red-950/60 border border-red-800/60 text-[11px]
                     font-mono text-red-200 hover:bg-red-900/60 transition-colors
                     disabled:hover:bg-red-950/60 disabled:cursor-default"
          title={message ? "Toggle error message" : undefined}
        >
          <svg viewBox="0 0 16 16" width="10" height="10" fill="currentColor" aria-hidden>
            <path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1Zm-.75 4h1.5v5h-1.5V5Zm.75 6.5a1 1 0 1 1 0 2 1 1 0 0 1 0-2Z"/>
          </svg>
          <span>Turn ended — {label}</span>
          {message && <span className="text-red-500">{expanded ? "▾" : "▸"}</span>}
        </button>
        {expanded && message && (
          <div className="text-[11px] text-red-100/80 bg-red-950/40 border border-red-900/40
                          rounded-md px-3 py-2 max-h-64 overflow-y-auto whitespace-pre-wrap
                          font-mono">
            {message}
          </div>
        )}
      </div>
      <div className="flex-1 border-t border-red-800/50" />
    </div>
  );
}

function _errorCodeLabel(code: string): string {
  switch (code) {
    case "context_too_long": return "context too long";
    case "rate_limit": return "rate limit";
    case "auth": return "auth";
    case "token_budget_exceeded": return "token budget exceeded";
    case "other": return "provider error";
    default: return code;
  }
}

// ── Project-change divider ──────────────────────────────────────────

/** Renders the "Project changed / set / cleared" marker inline in the
 *  transcript. Reuses the compaction divider's visual language (chip on
 *  a hairline rule) but tinted blue so the two are visually distinct at
 *  a glance. Body text is server-composed (`msg.text_content`) so all
 *  clients render the same label. */
function ProjectChangeDivider({ msg }: { msg: Message }) {
  return (
    <div className="my-4 flex items-center gap-3 px-1">
      <div className="flex-1 border-t border-blue-800/50" />
      <div className="max-w-[80%]">
        <span
          className="inline-flex items-center gap-2 px-2.5 py-1 rounded-full
                     bg-blue-950/60 border border-blue-800/60 text-[11px]
                     font-mono text-blue-200"
        >
          <svg viewBox="0 0 16 16" width="10" height="10" fill="currentColor" aria-hidden>
            <path d="M1.5 2h4l1 1h8v10H1.5V2zm1 1v9h11V4h-7.5l-1-1H2.5z"/>
          </svg>
          <span>{msg.text_content}</span>
        </span>
      </div>
      <div className="flex-1 border-t border-blue-800/50" />
    </div>
  );
}

/** Renders a `role: "date_marker"` row as a subtle inline divider:
 *  `── Mon, Oct 5 · 6 days later ──`. Deliberately quieter than the
 *  compaction / project-change / error dividers — this is an ambient
 *  time cue, not an event the user needs to act on. */
function DateMarkerDivider({ msg }: { msg: Message }) {
  const toDate = msg.metadata?.to_date;
  const days = msg.metadata?.elapsed_days ?? 0;
  const dateStr = _formatMarkerDate(toDate);
  const gap =
    days <= 0 ? "" : days === 1 ? " · next day" : ` · ${days} days later`;
  return (
    <div className="my-3 flex items-center gap-3 px-1">
      <div className="flex-1 border-t border-gray-800" />
      <span className="text-[10px] font-mono text-gray-500 whitespace-nowrap">
        {dateStr}{gap}
      </span>
      <div className="flex-1 border-t border-gray-800" />
    </div>
  );
}

function _formatMarkerDate(iso: string | undefined): string {
  if (!iso) return "";
  // Parse the ISO date as a local date (not UTC) so the display
  // reflects the day the user actually experienced. ark already
  // computed the date in the user's TZ.
  const parts = iso.split("-").map((n) => parseInt(n, 10));
  if (parts.length !== 3 || parts.some((n) => Number.isNaN(n))) return iso;
  const [y, m, d] = parts;
  const date = new Date(y, m - 1, d);
  return date.toLocaleDateString(undefined, {
    weekday: "short", month: "short", day: "numeric",
  });
}

function _compactionReasonLabel(reason: string): string {
  if (!reason) return "";
  if (reason === "client-invoked") return "manual";
  if (reason === "client-supplied") return "manual (supplied summary)";
  if (reason.startsWith("auto:")) return `auto (${reason.slice("auto:".length)})`;
  if (reason.startsWith("disabled:")) return `skipped: ${reason.slice("disabled:".length)}`;
  return reason;
}
