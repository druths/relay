import { useEffect, useRef } from "react";
import type { Message, FileAttachment } from "../types";
import { apiFetch } from "../api";

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
}

const ROLE_STYLES: Record<string, string> = {
  user: "bg-gray-800 ml-12 text-right msg-user",
  operator: "bg-blue-900/40 mr-12 msg-operator",
  agent: "bg-emerald-900/40 mr-12 msg-agent",
};


export function ConversationLog({
  lobbyMessages,
  sessionMessages,
  activeSessionId,
  activeAgentName,
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
      {messages.map((msg, i) => (
        <div
          key={i}
          className={`rounded-lg px-4 py-3 text-sm ${
            ROLE_STYLES[msg.role] || ROLE_STYLES.agent
          }`}
        >
          <div className="whitespace-pre-wrap">
            {msg.text_content}
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
      ))}
      <div ref={endRef} />
    </div>
  );
}
