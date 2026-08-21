import { useMemo, useState } from "react";
import type { Agent, Project, Session } from "../types";

interface Props {
  session: Session;
  /** The session's agent — used to filter `projects` to those hosted
   *  on the same ark server (ark rejects cross-server binds with 404,
   *  so any project on a different backend is unreachable regardless
   *  of what state the session is in). */
  agent: Agent | null;
  /** All ark projects the client knows about; filtered inside. */
  projects: Project[];
  onCancel: () => void;
  /** Called with `null` for detach or a project id for assignment. The
   *  parent is responsible for calling the API and closing the dialog
   *  on success. */
  onSubmit: (projectId: string | null) => Promise<void>;
}

/// Small modal for changing a session's ark project binding. Single
/// dropdown with `<None>` at the top, project names below. Save is
/// disabled while nothing has changed (so a stray click doesn't
/// generate a no-op PATCH) and while the request is in flight.
export function SetProjectDialog({ session, agent, projects, onCancel, onSubmit }: Props) {
  const current = session.project_id ?? null;
  const [selected, setSelected] = useState<string | null>(current);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Restrict the picker to projects on the same ark backend as the
  // session's agent. `server_id` on ark projects is the normalized
  // base URL, so we canonicalize the agent's URL the same way.
  const visibleProjects = useMemo(() => {
    const target = (agent?.llm_base_url ?? "").replace(/\/+$/, "");
    if (!target) return [];
    return projects.filter((p) => p.server_id === target);
  }, [projects, agent?.llm_base_url]);

  const dirty = selected !== current;

  const handleSave = async () => {
    if (!dirty || submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      await onSubmit(selected);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
      setSubmitting(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-[200] flex items-center justify-center bg-black/60 p-4"
      onClick={onCancel}
    >
      <div
        className="w-full max-w-md bg-gray-900 border border-gray-700 rounded-xl shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="px-5 py-4 border-b border-gray-800">
          <h3 className="text-sm font-semibold text-gray-100">Set project</h3>
          {session.name && (
            <p className="mt-1 text-xs text-gray-500 truncate">{session.name}</p>
          )}
        </div>
        <div className="px-5 py-4 text-xs text-gray-300 space-y-3">
          <div>
            <label className="block text-[11px] uppercase tracking-wide text-gray-500 mb-1.5">
              Project
            </label>
            <select
              value={selected ?? ""}
              onChange={(e) => setSelected(e.target.value ? e.target.value : null)}
              disabled={submitting}
              className="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5
                         text-sm text-gray-100 outline-none focus:ring-2 focus:ring-blue-500
                         disabled:opacity-60"
            >
              <option value="">&lt;None&gt;</option>
              {visibleProjects.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </div>
          <p className="text-[11px] text-gray-500 leading-relaxed">
            Choosing &lt;None&gt; detaches this session from any project.
            The agent will be notified of the change on the next turn;
            references to old project files will no longer resolve.
          </p>
          {error && (
            <p className="text-red-400 text-xs">{error}</p>
          )}
        </div>
        <div className="px-5 py-3 border-t border-gray-800 flex justify-end gap-2">
          <button
            onClick={onCancel}
            disabled={submitting}
            className="px-3 py-1.5 text-xs text-gray-300 hover:text-white transition-colors
                       disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            disabled={!dirty || submitting}
            className="px-3 py-1.5 text-xs bg-blue-600 hover:bg-blue-500
                       disabled:bg-gray-700 disabled:opacity-50 text-white rounded
                       transition-colors"
          >
            {submitting ? "Saving…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
