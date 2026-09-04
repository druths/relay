import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import type { Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Message, FileAttachment } from "../types";
import { apiFetch } from "../api";

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
        const usage = msg.metadata?.usage;
        const totalTokens =
          (usage?.input_tokens ?? 0) + (usage?.output_tokens ?? 0);
        const showUsage =
          diagnostics && msg.role === "agent" && usage && totalTokens > 0;
        const showTime = diagnostics && !!msg.created_at;
        const isRight = msg.role === "user";
        return (
        <div key={i}>
        <div
          className={`rounded-lg px-4 py-3 text-sm ${
            ROLE_STYLES[msg.role] || ROLE_STYLES.agent
          }`}
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
              <div className={`flex flex-col gap-1 ${msg.text_content ? "mt-2" : ""}`}>
                {msg.attachments.map((att, ai) => (
                  <button
                    key={ai}
                    type="button"
                    onClick={() => _downloadAttachment(att)}
                    className="inline-flex items-center gap-2 self-start px-2 py-1 rounded bg-gray-900/60 hover:bg-gray-900 border border-gray-700 text-xs text-gray-200"
                  >
                    <svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor" className="text-gray-400">
                      <path d="M9.5 0a.5.5 0 0 1 .5.5V3h2.5a.5.5 0 0 1 .5.5v11a.5.5 0 0 1-.5.5h-9a.5.5 0 0 1-.5-.5v-11a.5.5 0 0 1 .5-.5H6V.5a.5.5 0 0 1 .5-.5h3ZM4 4v10h8V4H4Z"/>
                    </svg>
                    <span className="truncate max-w-[20rem]">{att.filename}</span>
                    {att.size_bytes > 0 && (
                      <span className="text-gray-500">({_formatSize(att.size_bytes)})</span>
                    )}
                  </button>
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

function _compactionReasonLabel(reason: string): string {
  if (!reason) return "";
  if (reason === "client-invoked") return "manual";
  if (reason === "client-supplied") return "manual (supplied summary)";
  if (reason.startsWith("auto:")) return `auto (${reason.slice("auto:".length)})`;
  if (reason.startsWith("disabled:")) return `skipped: ${reason.slice("disabled:".length)}`;
  return reason;
}
