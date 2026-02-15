import type { Agent } from "../types";

interface AgentSelectorProps {
  agents: Agent[];
  activeSpeaker: string;
  onSelect: (agentName: string) => void;
  disabled: boolean;
}

export function AgentSelector({ agents, activeSpeaker, onSelect, disabled }: AgentSelectorProps) {
  const connectable = agents.filter((a) => a.name !== "Operator");

  return (
    <div className="space-y-2">
      <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider px-1">
        Agents
      </h3>
      <div className="space-y-1">
        {connectable.map((agent) => {
          const isActive =
            activeSpeaker.toLowerCase() === agent.name.toLowerCase();
          return (
            <button
              key={agent.agent_id}
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
                  className={`inline-block w-2 h-2 rounded-full flex-shrink-0 ${
                    agent.status === "healthy"
                      ? "bg-emerald-400"
                      : agent.status === "error"
                      ? "bg-red-400"
                      : "bg-gray-500"
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
          );
        })}
      </div>
    </div>
  );
}
