import type { Agent } from "../types";

interface AgentSelectorProps {
  agents: Agent[];
  activeSpeaker: string;
  onSelect: (agentName: string) => void;
  disabled: boolean;
  /** When provided, ark agents get a hover-visible kebab that calls this.
   * Non-ark agents stay on the operator/lobby path. */
  onCreateChat?: (agent: Agent) => void;
}

export function AgentSelector({ agents, activeSpeaker, onSelect, disabled, onCreateChat }: AgentSelectorProps) {
  const connectable = agents
    .filter((a) => a.name !== "Operator")
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));

  return (
    <div className="space-y-2">
      <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider px-1 section-label">
        Agents
      </h3>
      <div className="space-y-1">
        {connectable.map((agent) => {
          const isActive =
            activeSpeaker.toLowerCase() === agent.name.toLowerCase();
          const supportsCreateChat = onCreateChat != null && agent.llm_provider === "ark";
          return (
            <div key={agent.agent_id} className="group relative">
              <button
                onClick={() => onSelect(agent.name)}
                disabled={disabled}
                title={agent.status === "error" ? agent.status_message : undefined}
                className={`w-full text-left px-3 py-2 rounded-lg text-sm transition-colors
                  ${
                    isActive
                      ? "bg-emerald-900/50 text-emerald-300"
                      : "hover:bg-gray-800 text-gray-300"
                  }
                  disabled:opacity-50 disabled:cursor-not-allowed`}
              >
                <div className="font-medium flex items-center gap-2">
                  <span
                    className={`inline-block w-2 h-2 rounded-full flex-shrink-0 status-dot ${
                      agent.status === "healthy"
                        ? "bg-emerald-400"
                        : agent.status === "error"
                        ? "bg-red-400"
                        : "bg-blue-400"
                    }`}
                    title={
                      agent.status === "healthy"
                        ? "Available"
                        : agent.status === "error"
                        ? agent.status_message
                        : "Status unknown"
                    }
                  />
                  {agent.name}
                </div>
                <div className="text-xs text-gray-500 truncate ml-4">
                  {agent.status === "error" ? agent.status_message : agent.llm_provider ?? agent.tts_provider}
                </div>
              </button>
              {supportsCreateChat && (
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    onCreateChat!(agent);
                  }}
                  className="absolute right-2 top-1/2 -translate-y-1/2 p-1 rounded
                             opacity-0 group-hover:opacity-100 transition-opacity
                             text-gray-500 hover:text-gray-200 hover:bg-gray-700"
                  title="Create chat…"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
                    <circle cx="8" cy="3" r="1.5" />
                    <circle cx="8" cy="8" r="1.5" />
                    <circle cx="8" cy="13" r="1.5" />
                  </svg>
                </button>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
