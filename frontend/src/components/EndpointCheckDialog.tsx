import { useEffect, useState } from "react";
import type { Agent } from "../types";
import { apiFetch } from "../api";

/** Web modal that renders the structured EndpointReport from
 * `GET /v1/agents/{id}/endpoint-check`. Same shape as the iOS sheet —
 * summary pill at top, per-check rows in the middle (tap for extras),
 * pretty-printed `raw` dict at the bottom. */

type CheckStatus = "ok" | "warn" | "fail" | "skip";
type SummaryStatus = "healthy" | "degraded" | "down";

interface Check {
  name: string;
  status: CheckStatus;
  detail: string;
  elapsed_ms: number | null;
  extra: Record<string, unknown>;
}

interface EndpointReport {
  agent_id: string;
  agent_name: string;
  provider: string;
  model: string;
  base_url: string | null;
  summary_status: SummaryStatus;
  summary_message: string;
  checks: Check[];
  raw: Record<string, unknown>;
}

interface Props {
  agent: Agent;
  onClose: () => void;
}

export function EndpointCheckDialog({ agent, onClose }: Props) {
  const [report, setReport] = useState<EndpointReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [showRaw, setShowRaw] = useState(false);

  const run = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await apiFetch(
        `/v1/agents/${agent.agent_id}/endpoint-check`,
        { method: "GET" },
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
      const data: EndpointReport = await res.json();
      setReport(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void run();
    // run once on mount; explicit Refresh button covers re-runs.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const toggleExpand = (id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  return (
    <div className="fixed inset-0 z-50 bg-gray-950/80 flex items-start justify-center pt-16 px-4">
      <div className="bg-gray-900 rounded-xl border border-gray-800 w-full max-w-2xl modal-panel max-h-[85vh] flex flex-col">
        <div className="flex items-center justify-between px-5 py-3 border-b border-gray-800 flex-shrink-0">
          <h2 className="text-sm font-semibold">Endpoint Check</h2>
          <div className="flex items-center gap-2">
            <button
              onClick={run}
              disabled={loading}
              className="text-gray-400 hover:text-gray-200 text-xs px-2 py-1 rounded
                         hover:bg-gray-800 disabled:opacity-50"
              title="Run again"
            >
              ↻ Refresh
            </button>
            <button
              onClick={onClose}
              className="text-gray-500 hover:text-gray-300 text-lg"
            >
              ×
            </button>
          </div>
        </div>

        <div className="px-5 py-4 space-y-4 overflow-y-auto">
          <Header agent={agent} report={report} />

          {loading && (
            <div className="text-xs text-gray-500 italic">Running checks…</div>
          )}

          {error && (
            <div className="rounded-lg bg-red-950/40 border border-red-900 p-3">
              <div className="text-sm font-semibold text-red-300 mb-1">
                Check failed to run
              </div>
              <div className="text-xs font-mono text-gray-400">{error}</div>
            </div>
          )}

          {report && !loading && (
            <>
              <SummaryPill report={report} />
              <div className="space-y-px rounded-lg overflow-hidden border border-gray-800">
                {report.checks.map((c, idx) => {
                  const id = `${c.name}|${idx}`;
                  const isExpanded = expanded.has(id);
                  const hasExtra = c.extra && Object.keys(c.extra).length > 0;
                  return (
                    <CheckRow
                      key={id}
                      check={c}
                      expanded={isExpanded}
                      hasExtra={!!hasExtra}
                      onToggle={() => hasExtra && toggleExpand(id)}
                    />
                  );
                })}
              </div>

              <div className="pt-2">
                <button
                  onClick={() => setShowRaw((v) => !v)}
                  className="text-xs uppercase tracking-wider text-gray-500 hover:text-gray-300"
                >
                  {showRaw ? "▼" : "▶"} Technical details
                </button>
                {showRaw && (
                  <pre className="mt-2 p-3 bg-gray-950 rounded-lg text-xs text-gray-400
                                  font-mono overflow-auto max-h-80 border border-gray-800">
{JSON.stringify(report.raw, null, 2)}
                  </pre>
                )}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function Header({ agent, report }: { agent: Agent; report: EndpointReport | null }) {
  const baseUrl = report?.base_url ?? agent.llm_base_url ?? null;
  return (
    <div className="bg-gray-950 rounded-lg p-3 border border-gray-800">
      <div className="text-base font-semibold text-gray-100">{agent.name}</div>
      <div className="flex items-center gap-2 mt-1">
        <span className="inline-block px-2 py-0.5 rounded-full bg-gray-800
                         text-xs font-mono font-semibold text-gray-300">
          {agent.llm_provider}
        </span>
        <span className="text-xs font-mono text-gray-500 truncate">{agent.llm_model}</span>
      </div>
      {baseUrl && (
        <div className="text-xs font-mono text-gray-600 mt-1 truncate">{baseUrl}</div>
      )}
    </div>
  );
}

function SummaryPill({ report }: { report: EndpointReport }) {
  const colors: Record<SummaryStatus, { dot: string; text: string; bg: string }> = {
    healthy: { dot: "bg-emerald-400", text: "text-emerald-300", bg: "bg-emerald-950/40" },
    degraded: { dot: "bg-amber-400", text: "text-amber-300", bg: "bg-amber-950/40" },
    down: { dot: "bg-red-400", text: "text-red-300", bg: "bg-red-950/40" },
  };
  const labels: Record<SummaryStatus, string> = {
    healthy: "Healthy",
    degraded: "Degraded",
    down: "Down",
  };
  const c = colors[report.summary_status];
  return (
    <div className={`rounded-lg ${c.bg} p-3`}>
      <div className="flex items-center gap-2">
        <span className={`inline-block w-3 h-3 rounded-full ${c.dot}`} />
        <span className={`font-semibold ${c.text}`}>{labels[report.summary_status]}</span>
      </div>
      <div className="text-sm text-gray-300 mt-1">{report.summary_message}</div>
    </div>
  );
}

function CheckRow({
  check, expanded, hasExtra, onToggle,
}: { check: Check; expanded: boolean; hasExtra: boolean; onToggle: () => void }) {
  const icons: Record<CheckStatus, { symbol: string; color: string }> = {
    ok:   { symbol: "✓", color: "text-emerald-400" },
    warn: { symbol: "!", color: "text-amber-400" },
    fail: { symbol: "✕", color: "text-red-400" },
    skip: { symbol: "–", color: "text-gray-500" },
  };
  const ic = icons[check.status];
  return (
    <div
      className={`bg-gray-900 px-3 py-2 ${hasExtra ? "cursor-pointer hover:bg-gray-850" : ""}`}
      onClick={onToggle}
    >
      <div className="flex items-start gap-3">
        <span className={`text-base font-bold ${ic.color} mt-0.5 w-4`}>{ic.symbol}</span>
        <div className="flex-1 min-w-0">
          <div className="flex items-center justify-between gap-2">
            <span className="text-sm font-medium text-gray-200">{check.name}</span>
            {check.elapsed_ms != null && (
              <span className="text-xs font-mono text-gray-500">{check.elapsed_ms}ms</span>
            )}
          </div>
          <div className="text-xs font-mono text-gray-400 mt-0.5 break-words">{check.detail}</div>
        </div>
        {hasExtra && (
          <span className="text-xs text-gray-500 mt-1">{expanded ? "▲" : "▼"}</span>
        )}
      </div>
      {expanded && hasExtra && (
        <pre className="mt-2 ml-7 p-2 bg-gray-950 rounded text-xs text-gray-400
                        font-mono overflow-auto max-h-60 border border-gray-800">
{JSON.stringify(check.extra, null, 2)}
        </pre>
      )}
    </div>
  );
}
