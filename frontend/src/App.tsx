import { useCallback, useEffect, useRef, useState, type DragEvent } from "react";
import { isAuthenticated, clearToken } from "./hooks/useAuth";
import { LoginPage } from "./components/LoginPage";
import { useRelay } from "./hooks/useRelay";
import { StatusOrb } from "./components/StatusOrb";
import { ConversationLog } from "./components/ConversationLog";
import { TextInput } from "./components/TextInput";
import { AgentSelector } from "./components/AgentSelector";
import { AgentManagement } from "./components/AgentManagement";
import { ProjectManager } from "./components/ProjectManager";
import { FileBrowserPanel } from "./components/FileBrowserPanel";
import { FileEditorTab } from "./components/FileEditorTab";
import { uploadFiles } from "./api";

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
  const [showProjects, setShowProjects] = useState(false);
  const [showFileBrowser, setShowFileBrowser] = useState(false);
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

  // Per-session file tabs. The conversation is always the leading tab (id
  // `"conversation"`) and can't be closed. Files open into additional tabs
  // here when the user clicks them in the FileBrowserPanel. Ephemeral —
  // cleared when the session changes.
  interface FileTabState {
    tabId: string;        // `${kind}:${targetId}:${path}` — stable per file
    kind: "project" | "workspace";
    targetId: string;     // project_id or agent_id
    path: string;
    server?: string;
    /** ark `agent_name` (workspace) or `project_id` (project) — what
     * `FileEditorTab` uses to match `fileChanges` events. */
    scope: string;
    dirty: boolean;
  }
  const [openTabs, setOpenTabs] = useState<FileTabState[]>([]);
  /** Which file tab is currently shown in the top split pane. null when
   * no files are open (conversation takes the full pane) — `"conversation"`
   * is no longer a value because conversation lives below the splitter
   * permanently now. */
  const [activeTabId, setActiveTabId] = useState<string | null>(null);

  // Reset tabs whenever the session changes — leaving a session ditches
  // any open editors. Dirty-confirm on session leave isn't worth chasing
  // for v1; closing an individual tab already prompts.
  useEffect(() => {
    setOpenTabs([]);
    setActiveTabId(null);
  }, [relay.activeSessionId]);

  const openFileTab = useCallback((
    kind: "project" | "workspace", targetId: string, path: string,
    server: string | undefined, scope: string,
  ) => {
    const tabId = `${kind}:${targetId}:${path}`;
    setOpenTabs((tabs) =>
      tabs.find((t) => t.tabId === tabId)
        ? tabs
        : [...tabs, { tabId, kind, targetId, path, server, scope, dirty: false }],
    );
    setActiveTabId(tabId);
  }, []);

  const closeFileTab = useCallback((tabId: string) => {
    setOpenTabs((tabs) => {
      const tab = tabs.find((t) => t.tabId === tabId);
      if (tab?.dirty && !window.confirm("Discard unsaved changes?")) return tabs;
      const next = tabs.filter((t) => t.tabId !== tabId);
      setActiveTabId((curr) => {
        if (curr !== tabId) return curr;
        // Closing the active tab → fall back to the last remaining one,
        // or null if we just closed the only open file.
        return next.length > 0 ? next[next.length - 1].tabId : null;
      });
      return next;
    });
  }, []);

  // Splitter between the file pane (top) and the conversation (bottom).
  // Defaults to 360px, clamped on drag, persisted across reloads.
  const [filePaneHeight, setFilePaneHeight] = useState<number>(() => {
    const stored = Number(localStorage.getItem("relay_file_pane_height"));
    return Number.isFinite(stored) && stored >= 100 ? stored : 360;
  });
  const splitterDrag = useRef<{ y: number; h: number } | null>(null);

  const onSplitterDown = (e: React.PointerEvent<HTMLDivElement>) => {
    splitterDrag.current = { y: e.clientY, h: filePaneHeight };
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  };
  const onSplitterMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!splitterDrag.current) return;
    const dy = e.clientY - splitterDrag.current.y; // drag down = grow top pane
    const next = Math.min(
      Math.max(100, splitterDrag.current.h + dy),
      Math.max(160, window.innerHeight - 220),
    );
    setFilePaneHeight(next);
  };
  const onSplitterUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!splitterDrag.current) return;
    splitterDrag.current = null;
    (e.target as HTMLElement).releasePointerCapture(e.pointerId);
    try { localStorage.setItem("relay_file_pane_height", String(filePaneHeight)); }
    catch { /* ignore */ }
  };

  const setTabDirty = useCallback((tabId: string, dirty: boolean) => {
    setOpenTabs((tabs) =>
      tabs.map((t) => (t.tabId === tabId ? { ...t, dirty } : t)),
    );
  }, []);

  // Diagnostics is a global UI preference: when on, every conversation bubble
  // shows its timestamp; agent bubbles also show token usage if the message
  // carries ark-style metadata.
  const [diagnostics, setDiagnostics] = useState<boolean>(() => {
    try { return localStorage.getItem("relay_diagnostics") === "1"; }
    catch { return false; }
  });
  useEffect(() => {
    try { localStorage.setItem("relay_diagnostics", diagnostics ? "1" : "0"); }
    catch { /* ignore */ }
  }, [diagnostics]);

  // Drag-and-drop file uploads. HTML drag events fire on every nested child,
  // so we use a counter (not a boolean) to know when the cursor has actually
  // left the window vs. just crossed into a child element.
  const [isDraggingFile, setIsDraggingFile] = useState(false);
  const dragDepth = useRef(0);
  const [dropUploading, setDropUploading] = useState(false);

  const handleDragEnter = useCallback((e: DragEvent<HTMLDivElement>) => {
    // Only react to OS drags that actually carry files. Ignore text/element
    // drags happening inside the page.
    if (!e.dataTransfer?.types?.includes("Files")) return;
    e.preventDefault();
    dragDepth.current += 1;
    setIsDraggingFile(true);
  }, []);

  const handleDragOver = useCallback((e: DragEvent<HTMLDivElement>) => {
    if (!e.dataTransfer?.types?.includes("Files")) return;
    // preventDefault on dragover is what tells the browser this element is a
    // valid drop target — otherwise drop never fires.
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
  }, []);

  const handleDragLeave = useCallback((e: DragEvent<HTMLDivElement>) => {
    if (!e.dataTransfer?.types?.includes("Files")) return;
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (dragDepth.current === 0) setIsDraggingFile(false);
  }, []);

  const handleDrop = useCallback(async (e: DragEvent<HTMLDivElement>) => {
    if (!e.dataTransfer?.types?.includes("Files")) return;
    e.preventDefault();
    dragDepth.current = 0;
    setIsDraggingFile(false);
    const files = e.dataTransfer.files;
    if (!files || files.length === 0) return;
    setDropUploading(true);
    try {
      await uploadFiles(files, relay.activeSessionId, relay.appendUserAttachment);
    } finally {
      setDropUploading(false);
    }
  }, [relay.activeSessionId, relay.appendUserAttachment]);

  const handleAgentSelect = (agentName: string) => {
    relay.sendMessage(`connect me to ${agentName}`);
  };

  const inSession = relay.activeSessionId !== null;

  // The file-browser panel is offered when the active session is ark-backed
  // (workspace always available there) or bound to an ark project. Other
  // providers have no filesystem to show.
  const activeSession = relay.sessions.find((s) => s.session_id === relay.activeSessionId) ?? null;
  const activeAgent = relay.agents.find((a) => a.agent_id === activeSession?.agent_id) ?? null;
  const isArkAgent = activeAgent?.llm_provider === "ark";
  const showFileBrowserAvailable = !!activeSession && (isArkAgent || !!activeSession.project_id);

  // All labels across the user's full session history (server-side, not
  // limited to the 20 most-recent sessions currently in state).
  const allLabels = relay.allLabels;

  // Resolve `project_id` → name for chip rendering and search.
  const projectsById = new Map(relay.projects.map((p) => [p.id, p]));
  const projectNameOf = (sessionProjectId?: string | null) =>
    sessionProjectId ? projectsById.get(sessionProjectId)?.name ?? null : null;

  // Filter sessions by label and search. Search matches the session name,
  // agent name, label names, AND project name — chips and labels live in
  // the same conceptual space, so the search bar finds either.
  const filteredSessions = relay.sessions.filter((s) => {
    if (labelFilter && !s.labels?.includes(labelFilter)) return false;
    if (sessionSearch) {
      const q = sessionSearch.toLowerCase();
      const haystack = [
        s.name ?? "",
        s.agent_name,
        ...(s.labels ?? []),
        projectNameOf(s.project_id) ?? "",
      ]
        .join(" ")
        .toLowerCase();
      if (!haystack.includes(q)) return false;
    }
    return true;
  });

  // Debounced server-side refetch so sessions outside the 20-most-recent
  // cap remain findable when searching or filtering by label.
  useEffect(() => {
    const timer = setTimeout(() => {
      relay.fetchSessions({ search: sessionSearch, label: labelFilter ?? undefined });
    }, 250);
    return () => clearTimeout(timer);
  }, [sessionSearch, labelFilter, relay.fetchSessions]);

  // Global keyboard shortcuts: "/" focuses search, "m" focuses message input,
  // Escape blurs the current text field.
  useEffect(() => {
    const handler = (e: globalThis.KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const tag = target?.tagName;
      const inField = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";

      if (e.key === "Escape" && inField) {
        e.preventDefault();
        target?.blur();
        return;
      }

      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (inField) return;

      if (e.key === "/") {
        e.preventDefault();
        searchRef.current?.focus();
      } else if (e.key === "m" || e.key === "M") {
        const el = document.querySelector<HTMLTextAreaElement>("[data-message-input]");
        if (el) {
          e.preventDefault();
          el.focus();
        }
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
    <div
      className="h-screen flex relative"
      onDragEnter={handleDragEnter}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {isDraggingFile && (
        <div
          className="absolute inset-0 z-[100] pointer-events-none
                     flex items-center justify-center
                     bg-blue-500/10 border-4 border-dashed border-blue-400 rounded-lg"
        >
          <div className="px-6 py-4 rounded-lg bg-gray-900/90 border border-blue-400
                          text-blue-300 text-sm font-medium shadow-xl">
            Drop file to attach
          </div>
        </div>
      )}
      {dropUploading && !isDraggingFile && (
        <div className="absolute top-2 right-2 z-[100] px-3 py-1 rounded
                        bg-gray-900/90 border border-gray-700 text-xs text-gray-300">
          Uploading…
        </div>
      )}
      {/* Sidebar */}
      <aside className="w-64 border-r border-gray-800 flex flex-col gap-6 p-4 bg-gray-900/50 overflow-y-auto">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold tracking-tight">Relay</h1>
            <p className="text-xs text-gray-500">
              {inSession ? `Session with ${relay.activeAgentName}` : "Lobby"}
            </p>
          </div>
          <div className="flex items-center gap-1">
            <button
              onClick={() => setShowProjects(true)}
              className="text-gray-500 hover:text-gray-300 transition-colors p-1"
              title="Projects"
            >
              <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" viewBox="0 0 20 20" fill="currentColor">
                <path d="M2 5a2 2 0 012-2h3.586a1 1 0 01.707.293l1.121 1.121A2 2 0 0010.828 5H16a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V5z" />
              </svg>
            </button>
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
                  className="text-xs px-2 py-0.5 rounded-full transition-colors label-chip"
                  style={labelFilter === label
                    ? { backgroundColor: "var(--primary)", color: "var(--bg)" }
                    : { backgroundColor: "var(--elevated)", color: "var(--text-tertiary)" }
                  }
                >
                  {label}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Session list */}
        {relay.connected && relay.sessions.length > 0 && (
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
                      {((s.labels && s.labels.length > 0) || projectNameOf(s.project_id)) && (
                        <div className="flex flex-wrap gap-1 mt-1">
                          {projectNameOf(s.project_id) && (
                            <span
                              className="text-[10px] px-1.5 py-0 rounded-full
                                         bg-blue-900/40 border border-blue-800/60 text-blue-300"
                              title="Project"
                            >
                              {projectNameOf(s.project_id)}
                            </span>
                          )}
                          {s.labels?.map((label) => (
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
                                        rounded-lg shadow-lg py-1 w-44 dropdown-menu">
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
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              // For ark sessions, copy the ark server-side
                              // session id (useful for cron entries and
                              // `post_to_session`). Otherwise fall back to
                              // Relay's internal id.
                              const id =
                                s.provider_state?.ark ?? s.session_id;
                              navigator.clipboard.writeText(id).catch(() => {});
                              setMenuOpenId(null);
                            }}
                            className="w-full text-left px-3 py-1.5 text-sm text-gray-300
                                       hover:bg-gray-700 transition-colors"
                          >
                            Copy Session ID
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

            <div className="ml-auto relative flex items-center gap-1">
              {showFileBrowserAvailable && (
                <button
                  onClick={() => setShowFileBrowser((v) => !v)}
                  className={`p-1 transition-colors ${
                    showFileBrowser ? "text-blue-400" : "text-gray-500 hover:text-gray-300"
                  }`}
                  title="Files"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" className="w-4 h-4" viewBox="0 0 20 20" fill="currentColor">
                    <path d="M2 5a2 2 0 012-2h3.586a1 1 0 01.707.293l1.121 1.121A2 2 0 0010.828 5H16a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V5z" />
                  </svg>
                </button>
              )}
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
                                rounded-lg shadow-lg py-1 w-52 dropdown-menu">
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
                  <button
                    onClick={() => setDiagnostics((d) => !d)}
                    className="w-full text-left px-3 py-1.5 text-sm text-gray-300
                               hover:bg-gray-700 transition-colors flex items-center justify-between gap-2"
                  >
                    <span>Diagnostics</span>
                    <span className={`text-xs ${diagnostics ? "text-emerald-400" : "text-gray-500"}`}>
                      {diagnostics ? "✓" : ""}
                    </span>
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

        {/* Top split: file tab bar + active editor. Only renders when files
            are open. Conversation lives below — always visible — so the
            user can chat and watch a file at the same time. */}
        {inSession && openTabs.length > 0 && (
          <div
            className="flex flex-col flex-shrink-0 min-h-0 border-b border-gray-800"
            style={{ height: `${filePaneHeight}px` }}
          >
            <div className="flex border-b border-gray-800 bg-gray-900/40 text-xs overflow-x-auto flex-shrink-0">
              {openTabs.map((t) => {
                const filename = t.path.split("/").pop() || t.path;
                const active = activeTabId === t.tabId;
                return (
                  <div
                    key={t.tabId}
                    className={`flex items-center border-r border-gray-800 flex-shrink-0 ${
                      active ? "bg-gray-950 text-gray-100" : "text-gray-400 hover:text-gray-200"
                    }`}
                  >
                    <button
                      onClick={() => setActiveTabId(t.tabId)}
                      className="pl-3 pr-1 py-2 flex items-center gap-1.5"
                      title={t.path}
                    >
                      {t.dirty && <span className="w-1.5 h-1.5 rounded-full bg-amber-400" aria-label="unsaved" />}
                      <span className="font-mono">{filename}</span>
                    </button>
                    <button
                      onClick={() => closeFileTab(t.tabId)}
                      className="px-2 py-2 text-gray-500 hover:text-red-400"
                      title="Close tab"
                    >
                      ×
                    </button>
                  </div>
                );
              })}
            </div>
            <div className="flex-1 min-h-0 flex flex-col">
              {openTabs.map((t) => (
                activeTabId === t.tabId && (
                  <FileEditorTab
                    key={t.tabId}
                    kind={t.kind}
                    targetId={t.targetId}
                    path={t.path}
                    server={t.server}
                    scope={t.scope}
                    fileChanges={relay.fileChanges}
                    onDirtyChange={(dirty) => setTabDirty(t.tabId, dirty)}
                  />
                )
              ))}
            </div>
          </div>
        )}

        {/* Splitter — only present when files are open. Drag down/up to
            redistribute vertical space between the file pane and the
            conversation. */}
        {inSession && openTabs.length > 0 && (
          <div
            onPointerDown={onSplitterDown}
            onPointerMove={onSplitterMove}
            onPointerUp={onSplitterUp}
            onPointerCancel={onSplitterUp}
            className="h-1 -mt-px flex-shrink-0 cursor-row-resize
                       hover:bg-blue-500/40 active:bg-blue-500/60"
            title="Drag to resize"
          />
        )}

        {/* Conversation pane — always rendered at the bottom of `main`. */}
        <div className="flex-1 flex flex-col min-h-0">
          <ConversationLog
            lobbyMessages={relay.lobbyMessages}
            sessionMessages={relay.sessionMessages}
            activeSessionId={relay.activeSessionId}
            activeAgentName={relay.activeAgentName}
            diagnostics={diagnostics}
          />
          <TextInput
            onSend={relay.sendMessage}
            disabled={!relay.connected}
            sessionId={relay.activeSessionId}
            onAttachment={relay.appendUserAttachment}
          />
        </div>
      </main>

      {/* File browser side panel */}
      {showFileBrowser && showFileBrowserAvailable && activeSession && (
        <FileBrowserPanel
          agentId={activeSession.agent_id}
          agentName={activeSession.agent_name}
          // ark uses the agent's `llm_model` (minus any `ark:` prefix) as
          // its `agent_name` in `workspace_file_changed` events. Pass that
          // through so the panel's scope filter matches what ark sends.
          agentArkName={
            activeAgent?.llm_model
              ? activeAgent.llm_model.replace(/^ark:/, "")
              : activeSession.agent_name
          }
          projectId={activeSession.project_id ?? null}
          projectName={projectNameOf(activeSession.project_id)}
          projectServerId={activeSession.project_server_id ?? null}
          workspaceAvailable={isArkAgent}
          fileChanges={relay.fileChanges}
          onOpenFile={(kind, targetId, path, server) => {
            // Resolve the scope the way the editor tab expects it: ark
            // project ids for project files, the ark `agent_name` for
            // workspace files.
            const scope =
              kind === "project"
                ? targetId
                : (activeAgent?.llm_model
                    ? activeAgent.llm_model.replace(/^ark:/, "")
                    : activeSession.agent_name);
            openFileTab(kind, targetId, path, server, scope);
          }}
          onClose={() => setShowFileBrowser(false)}
        />
      )}

      {/* Agent Management modal */}
      {showSettings && (
        <AgentManagement
          agents={relay.agents}
          onClose={() => setShowSettings(false)}
          onAgentsChanged={relay.refreshAgents}
        />
      )}

      {/* Project Manager modal */}
      {showProjects && (
        <ProjectManager
          onClose={() => setShowProjects(false)}
          onChange={relay.refreshProjects}
        />
      )}
    </div>
  );
}

export default App;
