import { useEffect, useState } from "react";
import type { Project } from "../types";
import {
  createProject,
  deleteProject,
  listArkServers,
  listProjects,
  updateProject,
} from "../api";

interface Props {
  onClose: () => void;
  onChange?: () => void;
}

export function ProjectManager({ onClose, onChange }: Props) {
  const [servers, setServers] = useState<string[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = async () => {
    setLoading(true);
    try {
      const list = await listProjects();
      setProjects(list);
      if (selectedId && !list.find((p) => p.id === selectedId)) {
        setSelectedId(null);
      }
    } catch (err) {
      setError(String(err));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    refresh();
    (async () => {
      try {
        const list = await listArkServers();
        setServers(list.map((s) => s.server_id));
      } catch {
        // ignore
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const selected = projects.find((p) => p.id === selectedId) ?? null;

  return (
    <div className="fixed inset-0 z-50 bg-gray-950/90 flex items-start justify-center pt-12">
      <div className="bg-gray-900 rounded-xl border border-gray-800 w-full max-w-3xl max-h-[80vh] flex flex-col modal-panel">
        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-800">
          <h2 className="text-lg font-semibold">Projects</h2>
          <button
            onClick={onClose}
            className="text-gray-500 hover:text-gray-300 text-xl"
          >
            ×
          </button>
        </div>

        {error && (
          <div className="px-6 py-2 text-xs text-red-400 border-b border-gray-800">
            {error}
          </div>
        )}

        <div className="flex flex-1 min-h-0">
          {/* List */}
          <div className="w-56 border-r border-gray-800 flex flex-col p-3 gap-1 overflow-y-auto">
            <button
              onClick={() => setCreating(true)}
              className="text-left px-2 py-1.5 text-sm text-emerald-400 hover:bg-gray-800 rounded mb-1"
            >
              + New project
            </button>
            {loading && projects.length === 0 && (
              <div className="text-xs text-gray-600 px-2 py-1">Loading…</div>
            )}
            {projects.length === 0 && !loading && (
              <div className="text-xs text-gray-600 px-2 py-1">
                No projects yet.
              </div>
            )}
            {(() => {
              // Group projects by their ark server. If there's only one
              // server, render flat (no header noise). Otherwise show a
              // small header per server with its base URL.
              const grouped = new Map<string, typeof projects>();
              for (const p of projects) {
                const arr = grouped.get(p.server_id) ?? [];
                arr.push(p);
                grouped.set(p.server_id, arr);
              }
              const sortedServers = Array.from(grouped.keys()).sort();
              const multiServer = sortedServers.length > 1;
              return sortedServers.map((sid) => (
                <div key={sid}>
                  {multiServer && (
                    <div
                      className="text-[10px] uppercase tracking-wider text-gray-600
                                 px-2 pt-2 pb-1 truncate"
                      title={sid}
                    >
                      {sid.replace(/^https?:\/\//, "")}
                    </div>
                  )}
                  {grouped.get(sid)!.map((p) => (
                    <button
                      key={p.id}
                      onClick={() => {
                        setCreating(false);
                        setSelectedId(p.id);
                      }}
                      className={`w-full text-left px-2 py-1.5 rounded text-sm truncate ${
                        selectedId === p.id && !creating
                          ? "bg-gray-800 text-gray-100"
                          : "text-gray-400 hover:bg-gray-800"
                      }`}
                      title={p.name}
                    >
                      {p.name}
                    </button>
                  ))}
                </div>
              ));
            })()}
          </div>

          {/* Detail */}
          <div className="flex-1 overflow-y-auto p-6">
            {creating ? (
              <NewProjectForm
                servers={servers}
                onCreated={async (p) => {
                  setCreating(false);
                  setSelectedId(p.id);
                  await refresh();
                  onChange?.();
                }}
                onCancel={() => setCreating(false)}
              />
            ) : selected ? (
              <ProjectDetail
                project={selected}
                onUpdated={async () => {
                  await refresh();
                  onChange?.();
                }}
                onDeleted={async () => {
                  setSelectedId(null);
                  await refresh();
                  onChange?.();
                }}
              />
            ) : (
              <div className="text-gray-600 text-sm">
                Pick a project or create a new one.
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function NewProjectForm({
  servers,
  onCreated,
  onCancel,
}: {
  servers: string[];
  onCreated: (p: Project) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [context, setContext] = useState("");
  const [server, setServer] = useState(servers[0] ?? "");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim() || !server) return;
    setBusy(true);
    setErr(null);
    try {
      const p = await createProject(server, {
        name: name.trim(),
        description: description.trim() || undefined,
        project_context: context.trim() || undefined,
      });
      onCreated(p);
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <div>
        <label className="block text-xs text-gray-500 mb-1">Name *</label>
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                     focus:ring-2 focus:ring-blue-500"
          placeholder="marketing-brochure"
        />
      </div>
      <div>
        <label className="block text-xs text-gray-500 mb-1">Description</label>
        <input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                     focus:ring-2 focus:ring-blue-500"
          placeholder="Q4 product brochure draft"
        />
      </div>
      <div>
        <label className="block text-xs text-gray-500 mb-1">
          Project context (injected into agents working in this project)
        </label>
        <textarea
          value={context}
          onChange={(e) => setContext(e.target.value)}
          rows={4}
          className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                     focus:ring-2 focus:ring-blue-500 resize-y"
          placeholder="Tone: warm, professional.&#10;Audience: enterprise."
        />
      </div>
      {servers.length > 1 && (
        <div>
          <label className="block text-xs text-gray-500 mb-1">ark server</label>
          <select
            value={server}
            onChange={(e) => setServer(e.target.value)}
            className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                       focus:ring-2 focus:ring-blue-500"
          >
            {servers.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </div>
      )}
      {err && <div className="text-xs text-red-400">{err}</div>}
      <div className="flex gap-2">
        <button
          type="submit"
          disabled={!name.trim() || !server || busy}
          className="bg-emerald-600 hover:bg-emerald-500 disabled:bg-gray-700
                     disabled:opacity-50 rounded-lg px-4 py-2 text-sm"
        >
          {busy ? "Creating…" : "Create"}
        </button>
        <button
          type="button"
          onClick={onCancel}
          className="text-gray-400 hover:text-gray-200 text-sm px-2"
        >
          Cancel
        </button>
      </div>
    </form>
  );
}

function ProjectDetail({
  project,
  onUpdated,
  onDeleted,
}: {
  project: Project;
  onUpdated: () => void;
  onDeleted: () => void;
}) {
  const [name, setName] = useState(project.name);
  const [description, setDescription] = useState(project.description ?? "");
  const [context, setContext] = useState(project.project_context ?? "");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [savingField, setSavingField] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  // Reset local edit state when switching projects.
  useEffect(() => {
    setName(project.name);
    setDescription(project.description ?? "");
    setContext(project.project_context ?? "");
    setConfirmDelete(false);
    setErr(null);
  }, [project.id]);

  const persistField = async (
    field: "name" | "description" | "project_context",
    value: string,
  ) => {
    const original =
      field === "name"
        ? project.name
        : field === "description"
        ? project.description ?? ""
        : project.project_context ?? "";
    if (value === original) return;
    setSavingField(field);
    setErr(null);
    try {
      await updateProject(project.id, project.server_id, { [field]: value });
      onUpdated();
    } catch (e) {
      setErr(String(e));
    } finally {
      setSavingField(null);
    }
  };

  const handleDelete = async () => {
    setErr(null);
    try {
      await deleteProject(project.id, project.server_id);
      onDeleted();
    } catch (e) {
      setErr(String(e));
    }
  };

  return (
    <div className="space-y-4">
      <div>
        <label className="block text-xs text-gray-500 mb-1">
          Name {savingField === "name" && <span className="text-gray-600">(saving…)</span>}
        </label>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          onBlur={() => persistField("name", name)}
          className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                     focus:ring-2 focus:ring-blue-500"
        />
      </div>
      <div>
        <label className="block text-xs text-gray-500 mb-1">
          Description{" "}
          {savingField === "description" && <span className="text-gray-600">(saving…)</span>}
        </label>
        <input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          onBlur={() => persistField("description", description)}
          className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                     focus:ring-2 focus:ring-blue-500"
        />
      </div>
      <div>
        <label className="block text-xs text-gray-500 mb-1">
          Project context{" "}
          {savingField === "project_context" && <span className="text-gray-600">(saving…)</span>}
        </label>
        <textarea
          value={context}
          onChange={(e) => setContext(e.target.value)}
          onBlur={() => persistField("project_context", context)}
          rows={5}
          className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                     focus:ring-2 focus:ring-blue-500 resize-y font-mono"
        />
      </div>

      <div className="text-xs text-gray-500 space-y-1 border-t border-gray-800 pt-3 mt-4">
        {project.root && <div>Root: <span className="font-mono">{project.root}</span></div>}
        <div>
          Project id: <span className="font-mono">{project.id}</span>
        </div>
        <div>
          ark server: <span className="font-mono">{project.server_id}</span>
        </div>
      </div>

      {err && <div className="text-xs text-red-400">{err}</div>}

      <div className="border-t border-gray-800 pt-4 mt-4">
        {confirmDelete ? (
          <div className="flex items-center gap-3 text-sm">
            <span className="text-red-400">Soft-delete {project.name}?</span>
            <button
              onClick={handleDelete}
              className="text-red-400 hover:text-red-300 font-medium"
            >
              Confirm
            </button>
            <button
              onClick={() => setConfirmDelete(false)}
              className="text-gray-500 hover:text-gray-300"
            >
              Cancel
            </button>
            <span className="text-xs text-gray-600">
              (files survive on disk)
            </span>
          </div>
        ) : (
          <button
            onClick={() => setConfirmDelete(true)}
            className="text-sm text-red-400 hover:text-red-300"
          >
            Soft-delete project
          </button>
        )}
      </div>
    </div>
  );
}
