import { useMemo, useState } from "react";
import type { Agent, Project } from "../types";
import { createSession } from "../api";

interface Props {
  agent: Agent;
  /** All projects the client knows about. The dialog filters internally
   * to ones on the same ark server as the agent. */
  projects: Project[];
  onClose: () => void;
  /** Called with the new session id after a successful POST. The caller
   * should use this to enter the session. */
  onCreated: (sessionId: string) => void;
}

/** Quick create-a-session dialog launched from an agent's kebab menu.
 * Shorter path than going through the lobby + operator just to start a
 * project-bound chat. */
export function CreateChatDialog({ agent, projects, onClose, onCreated }: Props) {
  // Agents and projects both carry an ark backend identifier (base URL).
  // Surface only the projects on the same ark — different arks can't
  // hand off project_id to each other.
  const agentServer = agent.llm_base_url
    ? agent.llm_base_url.replace(/\/$/, "")
    : null;
  const compatibleProjects = useMemo(
    () => projects.filter((p) => p.server_id === agentServer),
    [projects, agentServer],
  );

  const [projectId, setProjectId] = useState<string>("");  // "" = No project
  const [name, setName] = useState<string>("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const selected = compatibleProjects.find((p) => p.id === projectId) ?? null;
      const sess = await createSession(
        agent.agent_id,
        selected?.id,
        selected?.server_id,
        name.trim() || undefined,
      );
      onCreated(sess.session_id);
      onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-gray-950/80 flex items-start justify-center pt-24">
      <div className="bg-gray-900 rounded-xl border border-gray-800 w-full max-w-md modal-panel">
        <div className="flex items-center justify-between px-5 py-3 border-b border-gray-800">
          <h2 className="text-sm font-semibold">Create chat</h2>
          <button
            onClick={onClose}
            className="text-gray-500 hover:text-gray-300 text-lg"
          >
            ×
          </button>
        </div>
        <form onSubmit={submit} className="px-5 py-4 space-y-4">
          <div>
            <label className="block text-xs text-gray-500 mb-1">Agent</label>
            <div className="text-sm text-gray-200">{agent.name}</div>
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">
              Name <span className="text-gray-600">(optional)</span>
            </label>
            <input
              autoFocus
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="(auto-named after a couple of turns)"
              className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                         focus:ring-2 focus:ring-blue-500 placeholder-gray-600"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">Project</label>
            <select
              value={projectId}
              onChange={(e) => setProjectId(e.target.value)}
              className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                         focus:ring-2 focus:ring-blue-500"
            >
              <option value="">No project</option>
              {compatibleProjects.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
            {compatibleProjects.length === 0 && (
              <div className="text-[11px] text-gray-500 mt-1">
                No projects on this agent's ark backend yet.
              </div>
            )}
          </div>
          {error && (
            <div className="text-xs text-red-400">{error}</div>
          )}
          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="text-sm text-gray-400 hover:text-gray-200 px-3 py-1.5"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy}
              className="text-sm bg-emerald-600 hover:bg-emerald-500
                         disabled:bg-gray-700 disabled:opacity-50
                         rounded-lg px-4 py-1.5 text-white font-medium"
            >
              {busy ? "Creating…" : "Create"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
