import { useCallback, useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { isAuthenticated, clearToken } from "./hooks/useAuth";
import { LoginPage } from "./components/LoginPage";
import { useRelay } from "./hooks/useRelay";
import { StatusOrb } from "./components/StatusOrb";
import { ConversationLog } from "./components/ConversationLog";
import { TextInput } from "./components/TextInput";
import { AgentSelector } from "./components/AgentSelector";
import { AgentManagement } from "./components/AgentManagement";

function App() {
  const [authed, setAuthed] = useState(isAuthenticated());

  if (!authed) {
    return <LoginPage onLogin={() => setAuthed(true)} />;
  }

  return <RelayApp onLogout={() => { clearToken(); setAuthed(false); }} />;
}

function RelayApp({ onLogout }: { onLogout: () => void }) {
  const relay = useRelay();
  const [showSettings, setShowSettings] = useState(false);
  const [menuOpenId, setMenuOpenId] = useState<string | null>(null);
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [confirmingDeleteId, setConfirmingDeleteId] = useState<string | null>(null);
  const [labelFilter, setLabelFilter] = useState<string | null>(null);
  const [sessionSearch, setSessionSearch] = useState("");
  const searchRef = useRef<HTMLInputElement>(null);

  // In-session state
  const [showSessionMenu, setShowSessionMenu] = useState(false);
  const [renamingSession, setRenamingSession] = useState(false);
  const [sessionRenameValue, setSessionRenameValue] = useState("");
  const [editingLabels, setEditingLabels] = useState(false);
  const [labelInputValue, setLabelInputValue] = useState("");

  const handleAgentSelect = (agentName: string) => {
    relay.sendMessage(`connect me to ${agentName}`);
  };

  const inSession = relay.activeSessionId !== null;

  // Collect all known labels from sessions
  const allLabels = Array.from(
    new Set(relay.sessions.flatMap((s) => s.labels || []))
  ).sort();

  // Filter sessions by label and search
  const filteredSessions = relay.sessions.filter((s) => {
    if (labelFilter && !s.labels?.includes(labelFilter)) return false;
    if (sessionSearch) {
      const q = sessionSearch.toLowerCase();
      const name = (s.name || s.agent_name).toLowerCase();
      if (!name.includes(q)) return false;
    }
    return true;
  });

  // Global "/" shortcut to focus search
  useEffect(() => {
    const handler = (e: globalThis.KeyboardEvent) => {
      if (e.key === "/" && !e.metaKey && !e.ctrlKey) {
        const tag = (e.target as HTMLElement)?.tagName;
        if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
        e.preventDefault();
        searchRef.current?.focus();
      }
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, []);

  // Close menu when clicking outside
  const menuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpenId(null);
        setConfirmingDeleteId(null);
      }
    };
    if (menuOpenId) document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [menuOpenId]);

  const handleRenameSubmit = useCallback((sessionId: string) => {
    if (renameValue.trim()) {
      relay.renameSession(sessionId, renameValue.trim());
    }
    setRenamingId(null);
    setRenameValue("");
  }, [renameValue, relay]);

  const handleSessionRenameSubmit = useCallback(() => {
    if (sessionRenameValue.trim() && relay.activeSessionId) {
      relay.renameSession(relay.activeSessionId, sessionRenameValue.trim());
    }
    setRenamingSession(false);
    setSessionRenameValue("");
  }, [sessionRenameValue, relay]);

  const handleAddLabel = useCallback(() => {
    if (labelInputValue.trim() && relay.activeSessionId) {
      const newLabels = [...relay.activeSessionLabels, labelInputValue.trim()];
      relay.updateSessionLabels(relay.activeSessionId, newLabels);
      setLabelInputValue("");
    }
  }, [labelInputValue, relay]);

  const handleRemoveLabel = useCallback((label: string) => {
    if (relay.activeSessionId) {
      const newLabels = relay.activeSessionLabels.filter((l) => l !== label);
      relay.updateSessionLabels(relay.activeSessionId, newLabels);
    }
  }, [relay]);

  return (
    <div className="h-screen flex">
      {/* Sidebar */}
      <aside className="w-64 border-r border-gray-800 flex flex-col gap-6 p-4 bg-gray-900/50 overflow-y-auto">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold tracking-tight">Relay</h1>
            <p className="text-xs text-gray-500">
              {inSession ? `Session with ${relay.activeAgentName}` : "Lobby"}
            </p>
          </div>
          <button
            onClick={() => setShowSettings(true)}
            className="text-gray-500 hover:text-gray-300 transition-colors p-1 settings-icon"
            title="Agent Management"
          >
            <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5 gear-icon" viewBox="0 0 20 20" fill="currentColor">
              <path fillRule="evenodd" d="M11.49 3.17c-.38-1.56-2.6-1.56-2.98 0a1.532 1.532 0 01-2.286.948c-1.372-.836-2.942.734-2.106 2.106.54.886.061 2.042-.947 2.287-1.561.379-1.561 2.6 0 2.978a1.532 1.532 0 01.947 2.287c-.836 1.372.734 2.942 2.106 2.106a1.532 1.532 0 012.287.947c.379 1.561 2.6 1.561 2.978 0a1.533 1.533 0 012.287-.947c1.372.836 2.942-.734 2.106-2.106a1.533 1.533 0 01.947-2.287c1.561-.379 1.561-2.6 0-2.978a1.532 1.532 0 01-.947-2.287c.836-1.372-.734-2.942-2.106-2.106a1.532 1.532 0 01-2.287-.947zM10 13a3 3 0 100-6 3 3 0 000 6z" clipRule="evenodd" />
            </svg>
            <span className="pixel-gear">*</span>
          </button>
        </div>

        <StatusOrb
          activeSpeaker={relay.activeSpeaker}
          displayName={relay.activeAgentName ?? undefined}
          status={relay.status}
          connected={relay.connected}
        />

        {relay.connected && inSession && (
          <button
            onClick={() => relay.leaveSession()}
            className="bg-amber-700 hover:bg-amber-600 rounded-lg px-4 py-2 text-sm
                       font-medium transition-colors"
          >
            Back to Lobby
          </button>
        )}

        {/* Agent selector */}
        {relay.connected && (
          <AgentSelector
            agents={relay.agents}
            activeSpeaker={relay.activeSpeaker}
            onSelect={handleAgentSelect}
            disabled={false}
          />
        )}

        {/* Label filter bar */}
        {relay.connected && allLabels.length > 0 && (
          <div className="space-y-1">
            <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider px-1 section-label">
              Labels
            </h3>
            <div className="flex flex-wrap gap-1 px-1">
              {allLabels.map((label) => (
                <button
                  key={label}
                  onClick={() => setLabelFilter(labelFilter === label ? null : label)}
                  className={`text-xs px-2 py-0.5 rounded-full transition-colors ${
                    labelFilter === label
                      ? "bg-blue-600 text-white"
                      : "bg-gray-800 text-gray-400 hover:bg-gray-700"
                  }`}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Session list */}
        {relay.connected && filteredSessions.length > 0 && (
          <div className="space-y-2">
            <div className="flex items-center gap-2 px-1">
              <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider section-label">
                {labelFilter ? `Sessions: ${labelFilter}` : "Sessions"}
              </h3>
              <div className="flex-1 flex items-center min-w-0">
                <input
                  ref={searchRef}
                  type="text"
                  value={sessionSearch}
                  onChange={(e) => setSessionSearch(e.target.value)}
                  onKeyDown={(e) => { if (e.key === "Escape") { setSessionSearch(""); searchRef.current?.blur(); } }}
                  placeholder="/"
                  className="flex-1 outline-none px-1 py-0.5 min-w-0 text-xs"
                  style={{
                    background: "transparent",
                    border: "none",
                    borderBottom: "1px solid var(--border)",
                    color: "var(--text-secondary)",
                  }}
                />
                {sessionSearch && (
                  <button
                    onClick={() => setSessionSearch("")}
                    className="text-gray-600 hover:text-gray-400 text-xs ml-1"
                  >
                    &times;
                  </button>
                )}
              </div>
            </div>
            <div className="space-y-1" ref={menuRef}>
              {filteredSessions.map((s) => (
                <div key={s.session_id} className="group relative">
                  {renamingId === s.session_id ? (
                    <form
                      onSubmit={(e) => { e.preventDefault(); handleRenameSubmit(s.session_id); }}
                      className="px-3 py-2"
                    >
                      <input
                        autoFocus
                        value={renameValue}
                        onChange={(e) => setRenameValue(e.target.value)}
                        onBlur={() => handleRenameSubmit(s.session_id)}
                        onKeyDown={(e) => { if (e.key === "Escape") { setRenamingId(null); setRenameValue(""); } }}
                        className="w-full bg-gray-800 border border-gray-600 rounded px-2 py-1 text-sm
                                   text-gray-200 focus:outline-none focus:border-blue-500"
                        placeholder="Session name..."
                      />
                    </form>
                  ) : (
                    <button
                      onClick={() => { setMenuOpenId(null); relay.resumeSession(s.session_id); }}
                      className={`w-full text-left px-3 py-2 pr-8 rounded-lg text-sm transition-colors ${
                        relay.activeSessionId === s.session_id
                          ? "bg-emerald-900/40 text-emerald-300 ring-1 ring-emerald-800 session-active"
                          : "hover:bg-gray-800 text-gray-300"
                      }`}
                    >
                      <div className="font-medium flex items-center gap-2">
                        {s.status === "processing" ? (
                          <span className="w-2 h-2 rounded-full flex-shrink-0 status-dot session-processing-dot bg-amber-500" />
                        ) : s.has_unread ? (
                          <span className="w-2 h-2 rounded-full bg-blue-500 flex-shrink-0 status-dot" />
                        ) : null}
                        {s.name || s.agent_name}
                      </div>
                      <div className="text-xs text-gray-500">
                        {s.agent_name} &middot; {s.status}
                      </div>
                      {s.labels && s.labels.length > 0 && (
                        <div className="flex flex-wrap gap-1 mt-1">
                          {s.labels.map((label) => (
                            <span
                              key={label}
                              className="text-[10px] px-1.5 py-0 rounded-full bg-gray-800 text-gray-500"
                            >
                              {label}
                            </span>
                          ))}
                        </div>
                      )}
                      {s.summary && (
                        <div className="text-xs text-gray-600 mt-0.5 line-clamp-2">
                          {s.summary}
                        </div>
                      )}
                    </button>
                  )}

                  {/* Kebab menu */}
                  {renamingId !== s.session_id && (
                    <div className="absolute right-2 top-3">
                      <button
                        onClick={(e) => {
                          e.stopPropagation();
                          setMenuOpenId(menuOpenId === s.session_id ? null : s.session_id);
                          setConfirmingDeleteId(null);
                        }}
                        className="opacity-0 group-hover:opacity-100 transition-opacity
                                   text-gray-600 hover:text-gray-400 p-0.5 rounded"
                        title="Session options"
                      >
                        <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
                          <circle cx="8" cy="3" r="1.5" />
                          <circle cx="8" cy="8" r="1.5" />
                          <circle cx="8" cy="13" r="1.5" />
                        </svg>
                      </button>

                      {menuOpenId === s.session_id && (
                        <div className="absolute right-0 top-6 z-50 bg-gray-800 border border-gray-700
                                        rounded-lg shadow-lg py-1 w-32 dropdown-menu">
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              setRenamingId(s.session_id);
                              setRenameValue(s.name || "");
                              setMenuOpenId(null);
                            }}
                            className="w-full text-left px-3 py-1.5 text-sm text-gray-300
                                       hover:bg-gray-700 transition-colors"
                          >
                            Rename
                          </button>
                          {confirmingDeleteId === s.session_id ? (
                            <div className="px-3 py-1.5 flex items-center gap-2">
                              <button
                                onClick={(e) => {
                                  e.stopPropagation();
                                  relay.deleteSession(s.session_id);
                                  setMenuOpenId(null);
                                  setConfirmingDeleteId(null);
                                }}
                                className="text-xs text-red-400 hover:text-red-300 font-medium"
                              >
                                Confirm
                              </button>
                              <button
                                onClick={(e) => {
                                  e.stopPropagation();
                                  setConfirmingDeleteId(null);
                                }}
                                className="text-xs text-gray-500 hover:text-gray-300"
                              >
                                Cancel
                              </button>
                            </div>
                          ) : (
                            <button
                              onClick={(e) => {
                                e.stopPropagation();
                                setConfirmingDeleteId(s.session_id);
                              }}
                              className="w-full text-left px-3 py-1.5 text-sm text-red-400
                                         hover:bg-gray-700 transition-colors"
                            >
                              Delete
                            </button>
                          )}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Logout */}
        <button
          onClick={onLogout}
          className="text-gray-600 hover:text-gray-400 text-xs mt-auto transition-colors"
        >
          Logout
        </button>
      </aside>

      {/* Main conversation area */}
      <main className="flex-1 flex flex-col">
        {/* In-session header bar */}
        {inSession && (
          <div className="flex items-center gap-2 px-4 py-2 border-b border-gray-800 bg-gray-900/50">
            <span className="text-sm font-medium text-gray-300">
              {relay.sessions.find((s) => s.session_id === relay.activeSessionId)?.name
                || relay.activeAgentName}
            </span>

            {/* Session labels */}
            {relay.activeSessionLabels.length > 0 && (
              <div className="flex gap-1">
                {relay.activeSessionLabels.map((label) => (
                  <span
                    key={label}
                    className="text-[10px] px-1.5 py-0 rounded-full bg-gray-800 text-gray-500"
                  >
                    {label}
                  </span>
                ))}
              </div>
            )}

            <div className="ml-auto relative">
              <button
                onClick={() => setShowSessionMenu(!showSessionMenu)}
                className="text-gray-500 hover:text-gray-300 transition-colors p-1"
                title="Session options"
              >
                <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
                  <circle cx="8" cy="3" r="1.5" />
                  <circle cx="8" cy="8" r="1.5" />
                  <circle cx="8" cy="13" r="1.5" />
                </svg>
              </button>

              {showSessionMenu && (
                <div className="absolute right-0 top-8 z-50 bg-gray-800 border border-gray-700
                                rounded-lg shadow-lg py-1 w-44 dropdown-menu">
                  <button
                    onClick={() => {
                      setRenamingSession(true);
                      setSessionRenameValue(
                        relay.sessions.find((s) => s.session_id === relay.activeSessionId)?.name || ""
                      );
                      setShowSessionMenu(false);
                    }}
                    className="w-full text-left px-3 py-1.5 text-sm text-gray-300
                               hover:bg-gray-700 transition-colors"
                  >
                    Rename session
                  </button>
                  <button
                    onClick={() => {
                      setEditingLabels(!editingLabels);
                      setShowSessionMenu(false);
                    }}
                    className="w-full text-left px-3 py-1.5 text-sm text-gray-300
                               hover:bg-gray-700 transition-colors"
                  >
                    Manage labels
                  </button>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Rename session inline */}
        {renamingSession && (
          <div className="px-4 py-2 border-b border-gray-800 bg-gray-900/30">
            <form
              onSubmit={(e) => { e.preventDefault(); handleSessionRenameSubmit(); }}
              className="flex gap-2"
            >
              <input
                autoFocus
                value={sessionRenameValue}
                onChange={(e) => setSessionRenameValue(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Escape") setRenamingSession(false); }}
                className="flex-1 bg-gray-800 border border-gray-600 rounded px-2 py-1 text-sm
                           text-gray-200 focus:outline-none focus:border-blue-500"
                placeholder="Session name..."
              />
              <button type="submit" className="text-sm text-blue-400 hover:text-blue-300">Save</button>
              <button type="button" onClick={() => setRenamingSession(false)} className="text-sm text-gray-500 hover:text-gray-300">Cancel</button>
            </form>
          </div>
        )}

        {/* Label editor inline */}
        {editingLabels && inSession && (
          <div className="px-4 py-2 border-b border-gray-800 bg-gray-900/30">
            <div className="flex flex-wrap gap-1 mb-2">
              {relay.activeSessionLabels.map((label) => (
                <span
                  key={label}
                  className="inline-flex items-center gap-1 text-xs px-2 py-0.5 rounded-full
                             bg-blue-600/20 text-blue-400"
                >
                  {label}
                  <button
                    onClick={() => handleRemoveLabel(label)}
                    className="hover:text-blue-200"
                  >
                    &times;
                  </button>
                </span>
              ))}
            </div>
            <form
              onSubmit={(e) => { e.preventDefault(); handleAddLabel(); }}
              className="flex gap-2"
            >
              <input
                autoFocus
                value={labelInputValue}
                onChange={(e) => setLabelInputValue(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Escape") setEditingLabels(false); }}
                className="flex-1 bg-gray-800 border border-gray-600 rounded px-2 py-1 text-sm
                           text-gray-200 focus:outline-none focus:border-blue-500"
                placeholder="Add a label..."
              />
              <button type="submit" className="text-sm text-blue-400 hover:text-blue-300">Add</button>
              <button type="button" onClick={() => setEditingLabels(false)} className="text-sm text-gray-500 hover:text-gray-300">Done</button>
            </form>
            {/* Existing labels as quick-add suggestions */}
            {(() => {
              const suggestions = allLabels.filter((l) => !relay.activeSessionLabels.includes(l));
              if (suggestions.length === 0) return null;
              return (
                <div className="flex flex-wrap gap-1 mt-2">
                  {suggestions.map((label) => (
                    <button
                      key={label}
                      onClick={() => {
                        if (relay.activeSessionId) {
                          relay.updateSessionLabels(relay.activeSessionId, [...relay.activeSessionLabels, label]);
                        }
                      }}
                      className="inline-flex items-center gap-1 text-xs px-2 py-0.5 rounded-full
                                 bg-gray-800 text-gray-500 hover:bg-gray-700 hover:text-gray-300
                                 transition-colors"
                    >
                      + {label}
                    </button>
                  ))}
                </div>
              );
            })()}
          </div>
        )}

        <ConversationLog
          lobbyMessages={relay.lobbyMessages}
          sessionMessages={relay.sessionMessages}
          activeSessionId={relay.activeSessionId}
          activeAgentName={relay.activeAgentName}
        />
        <TextInput
          onSend={relay.sendMessage}
          disabled={!relay.connected}
        />
      </main>

      {/* Agent Management modal */}
      {showSettings && (
        <AgentManagement
          agents={relay.agents}
          onClose={() => setShowSettings(false)}
          onAgentsChanged={relay.refreshAgents}
        />
      )}
    </div>
  );
}

export default App;
