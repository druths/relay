import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
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
                <AgentRowKebab
                  open={menuOpen}
                  onToggle={() => setMenuOpenId(menuOpen ? null : agent.agent_id)}
                  onClose={() => setMenuOpenId(null)}
                  items={[
                    supportsCreateChat
                      ? { label: "Create chat…", onClick: () => onCreateChat!(agent) }
                      : null,
                    supportsEndpointCheck
                      ? { label: "Endpoint check", onClick: () => onEndpointCheck!(agent) }
                      : null,
                  ].filter(Boolean) as MenuItem[]}
                />
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

interface MenuItem {
  label: string;
  onClick: () => void;
}

/** Kebab button plus its dropdown. The dropdown is rendered into a portal
 *  on `document.body` so it escapes the sidebar's `overflow-y-auto` clip
 *  and the surrounding semi-transparent stacking context — previously the
 *  menu was rendered inside the sidebar's overflow with a low z-index,
 *  which made it look half-clipped and partially transparent. */
function AgentRowKebab({
  open, onToggle, onClose, items,
}: {
  open: boolean;
  onToggle: () => void;
  onClose: () => void;
  items: MenuItem[];
}) {
  const buttonRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ top: number; right: number } | null>(null);

  // Position the portaled menu under the kebab.
  useLayoutEffect(() => {
    if (!open || !buttonRef.current) return;
    const rect = buttonRef.current.getBoundingClientRect();
    setPos({
      top: rect.bottom + 4,
      // Anchor by right edge so the menu's right side aligns with the
      // kebab's — looks the same as the previous absolute layout.
      right: window.innerWidth - rect.right,
    });
  }, [open]);

  // Close on outside click. The menu is in a portal so it isn't a DOM
  // descendant of the kebab — check both refs.
  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      const target = e.target as Node;
      if (buttonRef.current?.contains(target)) return;
      if (menuRef.current?.contains(target)) return;
      onClose();
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open, onClose]);

  // Close on scroll or resize — the anchored position would otherwise
  // drift away from the kebab.
  useEffect(() => {
    if (!open) return;
    const handler = () => onClose();
    window.addEventListener("scroll", handler, true);
    window.addEventListener("resize", handler);
    return () => {
      window.removeEventListener("scroll", handler, true);
      window.removeEventListener("resize", handler);
    };
  }, [open, onClose]);

  return (
    <div className="absolute right-2 top-1/2 -translate-y-1/2">
      <button
        ref={buttonRef}
        onClick={(e) => {
          e.stopPropagation();
          onToggle();
        }}
        className={`p-1 rounded transition-opacity
                    ${open ? "opacity-100" : "opacity-0 group-hover:opacity-100"}
                    text-gray-500 hover:text-gray-200 hover:bg-gray-700`}
        title="Actions"
      >
        <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
          <circle cx="8" cy="3" r="1.5" />
          <circle cx="8" cy="8" r="1.5" />
          <circle cx="8" cy="13" r="1.5" />
        </svg>
      </button>
      {open && pos && createPortal(
        <div
          ref={menuRef}
          className="fixed z-50 w-44 rounded-lg bg-gray-900 border border-gray-800
                     shadow-xl py-1"
          style={{ top: pos.top, right: pos.right }}
        >
          {items.map((item) => (
            <button
              key={item.label}
              onClick={() => {
                onClose();
                item.onClick();
              }}
              className="w-full text-left px-3 py-1.5 text-xs text-gray-200
                         hover:bg-gray-800"
            >
              {item.label}
            </button>
          ))}
        </div>,
        document.body,
      )}
    </div>
  );
}
