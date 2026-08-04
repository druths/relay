import { useState } from "react";
import type { AgentActivity } from "../hooks/useRelay";

/** Slim horizontal strip that surfaces what the agent is doing between
 *  the user's last message and the incoming response. Single-line by
 *  default showing the most recent activity ("💭 Thinking…", "🔧 bash",
 *  "✓ bash → …"); tapping expands to a chronological list of all
 *  activities in the current turn with raw JSON detail. Empty when
 *  the agent isn't mid-turn. */
export function AgentActivityStrip({ activities }: { activities: AgentActivity[] }) {
  const [expanded, setExpanded] = useState(false);
  if (activities.length === 0) return null;
  const current = activities[activities.length - 1];
  return (
    <div className="border-t border-gray-800 bg-gray-950/60">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="w-full px-4 py-1.5 flex items-center gap-2 text-left
                   text-[11px] font-mono text-gray-400 hover:bg-gray-900/60
                   transition-colors"
        title={expanded ? "Hide activity" : "Show activity"}
      >
        <span className="flex-1 truncate">
          <ActivityLine act={current} />
        </span>
        {activities.length > 1 && (
          <span className="text-gray-600">{activities.length} steps</span>
        )}
        <span className="text-gray-600">{expanded ? "▾" : "▸"}</span>
      </button>
      {expanded && (
        <div className="max-h-64 overflow-y-auto border-t border-gray-800/50
                        text-[11px] font-mono px-4 py-2 space-y-1.5">
          {activities.map((a, i) => (
            <ActivityRow key={i} act={a} />
          ))}
        </div>
      )}
    </div>
  );
}

// ── Rendering helpers ────────────────────────────────────────────────

function ActivityLine({ act }: { act: AgentActivity }) {
  if (act.kind === "thinking") {
    return (
      <span className="text-indigo-300">
        <span className="mr-1">💭</span>
        Thinking
        {act.text ? <span className="text-gray-500"> · {_truncate(act.text, 80)}</span> : null}
      </span>
    );
  }
  if (act.kind === "tool_call") {
    return (
      <span className="text-emerald-300">
        <span className="mr-1">🔧</span>
        {act.name}
        <span className="text-gray-500"> · {_summarizeInput(act.input)}</span>
      </span>
    );
  }
  // tool_result
  return (
    <span className={act.error ? "text-red-300" : "text-gray-300"}>
      <span className="mr-1">{act.error ? "⚠️" : "✓"}</span>
      result
      <span className="text-gray-500"> · {_summarizeOutput(act.output)}</span>
    </span>
  );
}

function ActivityRow({ act }: { act: AgentActivity }) {
  if (act.kind === "thinking") {
    return (
      <div>
        <div className="text-indigo-300">💭 Thinking</div>
        {act.text && (
          <pre className="mt-1 ml-4 whitespace-pre-wrap text-gray-400 text-[11px]">
            {act.text}
          </pre>
        )}
      </div>
    );
  }
  if (act.kind === "tool_call") {
    return (
      <div>
        <div className="text-emerald-300">🔧 {act.name}</div>
        <pre className="mt-1 ml-4 whitespace-pre-wrap text-gray-400 text-[11px]">
          {_prettyJson(act.input)}
        </pre>
      </div>
    );
  }
  return (
    <div>
      <div className={act.error ? "text-red-300" : "text-gray-300"}>
        {act.error ? "⚠️ result (error)" : "✓ result"}
      </div>
      <pre className="mt-1 ml-4 whitespace-pre-wrap text-gray-400 text-[11px]">
        {_prettyJson(act.output)}
      </pre>
    </div>
  );
}

function _truncate(s: string, n: number): string {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > n ? flat.slice(0, n) + "…" : flat;
}

function _prettyJson(v: unknown): string {
  if (typeof v === "string") return v;
  try {
    return JSON.stringify(v, null, 2);
  } catch {
    return String(v);
  }
}

function _summarizeInput(input: unknown): string {
  if (input == null) return "";
  if (typeof input === "string") return _truncate(input, 60);
  if (typeof input === "object") {
    // Prefer a `command` / `path` / `query` field if present; otherwise
    // show the first key's value or just a key count.
    const obj = input as Record<string, unknown>;
    for (const k of ["command", "path", "file_path", "query", "url", "prompt"]) {
      if (typeof obj[k] === "string") return _truncate(String(obj[k]), 60);
    }
    const keys = Object.keys(obj);
    if (keys.length === 0) return "{}";
    const first = obj[keys[0]];
    if (typeof first === "string") return _truncate(String(first), 60);
    return `{${keys.length} field${keys.length === 1 ? "" : "s"}}`;
  }
  return String(input);
}

function _summarizeOutput(output: unknown): string {
  if (output == null) return "";
  if (typeof output === "string") return _truncate(output, 70);
  return _truncate(_prettyJson(output), 70);
}
