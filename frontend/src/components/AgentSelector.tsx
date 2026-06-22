import { useEffect, useRef, useState } from "react";
import type { Agent } from "../types";

interface AgentSelectorProps {
  agents: Agent[];
  activeSpeaker: string;
  onSelect: (agentName: string) => void;
  disabled: boolean;
  /** When provided, ark agents get a "Create chat…" action in the kebab. */
  onCreateChat?: (agent: Agent) => void;
  /** When provided, every agent gets an "Endpoint check" action in the
   * kebab. The kebab itself is now visible whenever any action exists. */
  onEndpointCheck?: (agent: Agent) => void;
}

export function AgentSelector({
  agents, activeSpeaker, onSelect, disabled, onCreateChat, onEndpointCheck,
}: AgentSelectorProps) {
  const connectable = agents
    .filter((a) => a.name !== "Operator")
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
  const [menuOpenId, setMenuOpenId] = useState<string | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  // Close menu on outside click.
  useEffect(() => {
    if (!menuOpenId) return;
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpenId(null);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [menuOpenId]);

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
          const supportsEndpointCheck = onEndpointCheck != null;
          const showKebab = supportsCreateChat || supportsEndpointCheck;
          const menuOpen = menuOpenId === agent.agent_id;
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
              {showKebab && (
                <div
                  ref={menuOpen ? menuRef : undefined}
                  className="absolute right-2 top-1/2 -translate-y-1/2"
                >
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      setMenuOpenId(menuOpen ? null : agent.agent_id);
                    }}
                    className={`p-1 rounded transition-opacity
                                ${menuOpen ? "opacity-100" : "opacity-0 group-hover:opacity-100"}
                                text-gray-500 hover:text-gray-200 hover:bg-gray-700`}
                    title="Actions"
                  >
                    <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
                      <circle cx="8" cy="3" r="1.5" />
                      <circle cx="8" cy="8" r="1.5" />
                      <circle cx="8" cy="13" r="1.5" />
                    </svg>
                  </button>
                  {menuOpen && (
                    <div className="absolute right-0 top-full mt-1 z-10 w-44 rounded-lg
                                    bg-gray-900 border border-gray-800 shadow-lg py-1">
                      {supportsCreateChat && (
                        <button
                          onClick={() => {
                            setMenuOpenId(null);
                            onCreateChat!(agent);
                          }}
                          className="w-full text-left px-3 py-1.5 text-xs text-gray-200
                                     hover:bg-gray-800"
                        >
                          Create chat…
                        </button>
                      )}
                      {supportsEndpointCheck && (
                        <button
                          onClick={() => {
                            setMenuOpenId(null);
                            onEndpointCheck!(agent);
                          }}
                          className="w-full text-left px-3 py-1.5 text-xs text-gray-200
                                     hover:bg-gray-800"
                        >
                          Endpoint check
                        </button>
                      )}
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
