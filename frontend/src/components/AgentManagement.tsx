import { useEffect, useState } from "react";
import type { Agent, PlatformSettings } from "../types";
import {
  LLM_PROVIDERS,
  TTS_PROVIDERS,
  LLM_PROVIDER_OPTIONS,
  TTS_PROVIDER_OPTIONS,
  STT_PROVIDER_OPTIONS,
} from "../providerSchemas";
import { apiFetch } from "../api";
import { type ThemeName, getStoredTheme, applyTheme } from "../theme";

interface Voice {
  id: string;
  name: string;
  description: string;
}

interface Props {
  agents: Agent[];
  onClose: () => void;
  onAgentsChanged: () => void;
}

type Tab = "agents" | "tts" | "stt" | "appearance";

export function AgentManagement({ agents, onClose, onAgentsChanged }: Props) {
  const [tab, setTab] = useState<Tab>("agents");
  const [currentTheme, setCurrentTheme] = useState<ThemeName>(getStoredTheme());

  // ── Agent state ──
  const sorted = [...agents].sort((a, b) => {
    if (a.is_operator) return -1;
    if (b.is_operator) return 1;
    return a.sort_order - b.sort_order || a.name.localeCompare(b.name);
  });

  const nonOperator = sorted.filter((a) => !a.is_operator);
  const [dragId, setDragId] = useState<string | null>(null);

  const handleDrop = async (targetId: string) => {
    if (!dragId || dragId === targetId) return;
    const fromIdx = nonOperator.findIndex((a) => a.agent_id === dragId);
    const toIdx = nonOperator.findIndex((a) => a.agent_id === targetId);
    if (fromIdx < 0 || toIdx < 0) return;
    const reordered = [...nonOperator];
    const [moved] = reordered.splice(fromIdx, 1);
    reordered.splice(toIdx, 0, moved);
    setDragId(null);
    await apiFetch("/v1/agents/reorder", {
      method: "PUT",
      body: JSON.stringify({ agent_ids: reordered.map((a) => a.agent_id) }),
    });
    onAgentsChanged();
  };

  const [selectedId, setSelectedId] = useState<string | null>(
    sorted[0]?.agent_id ?? null
  );
  const [isNew, setIsNew] = useState(false);
  const [form, setForm] = useState<Record<string, string | null>>({});
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [voices, setVoices] = useState<Voice[]>([]);

  // ── Platform settings state ──
  const [platform, setPlatform] = useState<PlatformSettings | null>(null);
  const [platformForm, setPlatformForm] = useState<Record<string, string>>({});
  const [savingPlatform, setSavingPlatform] = useState(false);

  const selected = isNew ? null : agents.find((a) => a.agent_id === selectedId);

  // Load platform settings
  useEffect(() => {
    apiFetch(`/v1/platform/settings`)
      .then((r) => r.json())
      .then((data: PlatformSettings) => {
        setPlatform(data);
        setPlatformForm({
          stt_provider: data.stt_provider,
          stt_api_key: data.stt_api_key ?? "",
          stt_silence_threshold_db: String(data.stt_silence_threshold_db),
          stt_silence_timeout_ms: String(data.stt_silence_timeout_ms),
          stt_min_duration_ms: String(data.stt_min_duration_ms),
          stt_no_speech_threshold: String(data.stt_no_speech_threshold),
          tts_default_provider: data.tts_default_provider ?? "none",
          tts_openai_api_key: "",
          tts_elevenlabs_api_key: "",
        });
      })
      .catch(console.error);
  }, []);

  // When selection changes, reset form
  useEffect(() => {
    if (isNew) {
      setForm({
        name: "",
        persona_prompt: "",
        llm_provider: "openai",
        llm_model: "gpt-4o-mini",
        llm_base_url: "",
        llm_api_key: "",
        tts_provider: "none",
        tts_api_key: "",
        voice_id: "",
        speed: "1",
        model: "tts-1",
        model_id: "eleven_multilingual_v2",
        stability: "0.5",
        similarity_boost: "0.75",
      });
    } else if (selected) {
      setForm({
        name: selected.name,
        persona_prompt: selected.persona_prompt,
        llm_provider: selected.llm_provider,
        llm_model: selected.llm_model,
        llm_base_url: selected.llm_base_url ?? "",
        llm_api_key: selected.llm_api_key ?? "",
        tts_provider: selected.tts_provider,
        tts_api_key: selected.tts_api_key ?? "",
        voice_id: selected.voice_id,
        speed: String(selected.voice_settings?.speed ?? 1),
        model: String(selected.voice_settings?.model ?? "tts-1"),
        base_url: String(selected.voice_settings?.base_url ?? ""),
        model_id: String(selected.voice_settings?.model_id ?? "eleven_multilingual_v2"),
        stability: String(selected.voice_settings?.stability ?? 0.5),
        similarity_boost: String(selected.voice_settings?.similarity_boost ?? 0.75),
      });
    }
    setConfirmDelete(false);
  }, [selectedId, isNew, selected?.agent_id]);

  const [ttsModels, setTtsModels] = useState<{ id: string; name: string }[]>([]);

  // Fetch TTS models when provider, API key, or base URL changes
  const ttsProvider = form.tts_provider ?? "none";
  const ttsFormKey = form.tts_api_key ?? "";
  const ttsModelId = form.model_id ?? "";
  const ttsBaseUrl = form.base_url ?? "";
  useEffect(() => {
    if (ttsProvider !== "openai") {
      setTtsModels([]);
      return;
    }
    const timer = setTimeout(() => {
      const isRealKey = ttsFormKey && !ttsFormKey.includes("••");
      const params = new URLSearchParams();
      if (isRealKey) params.set("api_key", ttsFormKey);
      if (ttsBaseUrl) params.set("base_url", ttsBaseUrl);
      const qs = params.size ? `?${params.toString()}` : "";
      apiFetch(`/v1/agents/tts/models/${ttsProvider}${qs}`)
        .then((r) => r.json())
        .then((data: { id: string; name: string }[]) => setTtsModels(data))
        .catch(() => setTtsModels([]));
    }, 500);
    return () => clearTimeout(timer);
  }, [ttsProvider, ttsFormKey, ttsBaseUrl]);

  // Fetch the available LLM agents/models for providers that list them
  // (currently just ark — list is empty for everyone else).
  const [llmModels, setLlmModels] = useState<{ id: string; name: string; description?: string }[]>([]);
  useEffect(() => {
    const provider = form.llm_provider ?? "openai";
    if (provider !== "ark") {
      setLlmModels([]);
      return;
    }
    const baseUrl = form.llm_base_url || "";
    if (!baseUrl) {
      setLlmModels([]);
      return;
    }
    const apiKey = form.llm_api_key || "";
    const isRealKey = apiKey && !apiKey.includes("•");
    const params = new URLSearchParams();
    params.set("base_url", baseUrl);
    if (isRealKey) params.set("api_key", apiKey);
    const timer = setTimeout(() => {
      apiFetch(`/v1/agents/llm/models/${provider}?${params.toString()}`)
        .then((r) => r.json())
        .then((data) => setLlmModels(Array.isArray(data) ? data : []))
        .catch(() => setLlmModels([]));
    }, 300);
    return () => clearTimeout(timer);
  }, [form.llm_provider, form.llm_base_url, form.llm_api_key]);

  // Fetch voices when TTS provider, API key, or model changes
  useEffect(() => {
    if (ttsProvider === "none") {
      setVoices([]);
      return;
    }
    // Pass the agent's per-agent key if it's a real key (not masked "••••…")
    const isRealKey = ttsFormKey && !ttsFormKey.includes("\u2022");
    const params = new URLSearchParams();
    if (isRealKey) params.set("api_key", ttsFormKey);
    if (ttsProvider === "elevenlabs" && ttsModelId) params.set("model_id", ttsModelId);
    if (ttsBaseUrl) params.set("base_url", ttsBaseUrl);
    const qs = params.size ? `?${params.toString()}` : "";
    const timer = setTimeout(() => {
      apiFetch(`/v1/agents/tts/voices/${ttsProvider}${qs}`)
        .then((r) => r.json())
        .then((data: Voice[]) => setVoices(data))
        .catch(() => setVoices([]));
    }, 300);
    return () => clearTimeout(timer);
  }, [ttsProvider, ttsFormKey, ttsModelId]);

  const setField = (key: string, value: string) =>
    setForm((f) => ({ ...f, [key]: value }));

  // ── Save agent ──
  const handleSave = async () => {
    setSaving(true);
    try {
      const buildVoiceSettings = (): Record<string, unknown> => {
        const provider = form.tts_provider || "none";
        if (provider === "openai") {
          const settings: Record<string, unknown> = { speed: parseFloat(form.speed || "1"), model: form.model || "tts-1" };
          if (form.base_url) settings.base_url = form.base_url;
          return settings;
        }
        if (provider === "elevenlabs") {
          return {
            stability: parseFloat(form.stability || "0.5"),
            similarity_boost: parseFloat(form.similarity_boost || "0.75"),
            model_id: form.model_id || "eleven_multilingual_v2",
          };
        }
        return {};
      };

      if (isNew) {
        const body: Record<string, unknown> = {
          name: form.name,
          persona_prompt: form.persona_prompt ?? "",
          llm_provider: form.llm_provider,
          llm_model: form.llm_model,
          llm_base_url: form.llm_base_url || null,
          llm_api_key: form.llm_api_key || null,
          tts_provider: form.tts_provider || "none",
          tts_api_key: form.tts_api_key || null,
          voice_id: form.voice_id || "",
          voice_settings: buildVoiceSettings(),
        };
        const res = await apiFetch(`/v1/agents`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        });
        if (!res.ok) throw new Error(await res.text());
        const created: Agent = await res.json();
        setIsNew(false);
        setSelectedId(created.agent_id);
      } else if (selected) {
        const body: Record<string, unknown> = {
          persona_prompt: form.persona_prompt,
          llm_provider: form.llm_provider,
          llm_model: form.llm_model,
          llm_base_url: form.llm_base_url || "",
          tts_provider: form.tts_provider || "none",
          voice_id: form.voice_id || "",
          voice_settings: buildVoiceSettings(),
        };
        if (!selected.is_operator && form.name !== selected.name) {
          body.name = form.name;
        }
        // API keys: send only if changed from the masked original.
        // Empty string clears the key (falls back to platform default).
        if (form.llm_api_key !== (selected.llm_api_key ?? "")) {
          body.llm_api_key = form.llm_api_key;
        }
        if (form.tts_api_key !== (selected.tts_api_key ?? "")) {
          body.tts_api_key = form.tts_api_key;
        }

        const res = await apiFetch(`/v1/agents/${selected.agent_id}/config`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        });
        if (!res.ok) throw new Error(await res.text());
      }
      onAgentsChanged();
    } catch (err) {
      console.error("Save failed:", err);
    } finally {
      setSaving(false);
    }
  };

  // ── Delete agent ──
  const handleDelete = async () => {
    if (!selected || selected.is_operator) return;
    if (!confirmDelete) {
      setConfirmDelete(true);
      return;
    }
    setDeleting(true);
    try {
      const res = await apiFetch(`/v1/agents/${selected.agent_id}`, {
        method: "DELETE",
      });
      if (!res.ok) throw new Error(await res.text());
      setSelectedId(sorted[0]?.agent_id ?? null);
      onAgentsChanged();
    } catch (err) {
      console.error("Delete failed:", err);
    } finally {
      setDeleting(false);
      setConfirmDelete(false);
    }
  };

  // ── Save platform settings ──
  const handleSavePlatform = async () => {
    setSavingPlatform(true);
    try {
      const body: Record<string, unknown> = {};
      if (platformForm.stt_provider) body.stt_provider = platformForm.stt_provider;
      // Send API key only if changed from the masked original; empty string clears.
      if (platformForm.stt_api_key !== (platform?.stt_api_key ?? "")) {
        body.stt_api_key = platformForm.stt_api_key;
      }
      body.stt_silence_threshold_db = parseFloat(platformForm.stt_silence_threshold_db || "-35");
      body.stt_silence_timeout_ms = parseInt(platformForm.stt_silence_timeout_ms || "500");
      body.stt_min_duration_ms = parseInt(platformForm.stt_min_duration_ms || "400");
      body.stt_no_speech_threshold = parseFloat(platformForm.stt_no_speech_threshold || "0.5");
      const res = await apiFetch(`/v1/platform/settings`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(await res.text());
      const updated: PlatformSettings = await res.json();
      setPlatform(updated);
      setPlatformForm((f) => ({
        ...f,
        stt_api_key: updated.stt_api_key ?? "",
        stt_silence_threshold_db: String(updated.stt_silence_threshold_db),
        stt_silence_timeout_ms: String(updated.stt_silence_timeout_ms),
        stt_min_duration_ms: String(updated.stt_min_duration_ms),
        stt_no_speech_threshold: String(updated.stt_no_speech_threshold),
      }));
    } catch (err) {
      console.error("Platform settings save failed:", err);
    } finally {
      setSavingPlatform(false);
    }
  };

  // ── Save TTS platform settings ──
  const handleSaveTtsPlatform = async () => {
    setSavingPlatform(true);
    try {
      const body: Record<string, unknown> = {};
      if (platformForm.tts_default_provider) body.tts_default_provider = platformForm.tts_default_provider;
      if (platformForm.tts_openai_api_key) body.tts_openai_api_key = platformForm.tts_openai_api_key;
      if (platformForm.tts_elevenlabs_api_key) body.tts_elevenlabs_api_key = platformForm.tts_elevenlabs_api_key;
      const res = await apiFetch(`/v1/platform/settings`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(await res.text());
      const updated: PlatformSettings = await res.json();
      setPlatform(updated);
      setPlatformForm((f) => ({
        ...f,
        tts_default_provider: updated.tts_default_provider ?? "none",
        tts_openai_api_key: "",
        tts_elevenlabs_api_key: "",
      }));
    } catch (err) {
      console.error("TTS platform settings save failed:", err);
    } finally {
      setSavingPlatform(false);
    }
  };

  const llmSchema = LLM_PROVIDERS[form.llm_provider ?? "openai"];
  const ttsSchema = TTS_PROVIDERS[form.tts_provider ?? "none"];

  return (
    <div className="fixed inset-0 z-50 bg-gray-950/90 flex items-start justify-center pt-12">
      <div className="bg-gray-900 rounded-xl border border-gray-800 w-full max-w-4xl max-h-[90vh] flex flex-col modal-panel">
        {/* Header with tabs */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-800">
          <div className="flex items-center gap-6">
            <h2 className="text-lg font-semibold">Settings</h2>
            <div className="flex gap-1">
              <button
                onClick={() => setTab("agents")}
                className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                  tab === "agents"
                    ? "bg-gray-800 text-white"
                    : "text-gray-400 hover:text-gray-300"
                }`}
              >
                Agents
              </button>
              <button
                onClick={() => setTab("tts")}
                className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                  tab === "tts"
                    ? "bg-gray-800 text-white"
                    : "text-gray-400 hover:text-gray-300"
                }`}
              >
                Text to Speech
              </button>
              <button
                onClick={() => setTab("stt")}
                className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                  tab === "stt"
                    ? "bg-gray-800 text-white"
                    : "text-gray-400 hover:text-gray-300"
                }`}
              >
                Speech to Text
              </button>
              <button
                onClick={() => setTab("appearance")}
                className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                  tab === "appearance"
                    ? "bg-gray-800 text-white"
                    : "text-gray-400 hover:text-gray-300"
                }`}
              >
                Appearance
              </button>
            </div>
          </div>
          <button onClick={onClose} className="text-gray-500 hover:text-gray-300 text-xl">
            &times;
          </button>
        </div>

        {/* ════════ Agents Tab ════════ */}
        {tab === "agents" && (
          <div className="flex flex-1 min-h-0">
            {/* Left panel — agent list */}
            <div className="w-56 border-r border-gray-800 flex flex-col p-3 gap-1 overflow-y-auto">
              {sorted.map((a) => (
                <div
                  key={a.agent_id}
                  draggable={!a.is_operator}
                  onDragStart={() => setDragId(a.agent_id)}
                  onDragEnd={() => setDragId(null)}
                  onDragOver={(e) => { if (!a.is_operator) e.preventDefault(); }}
                  onDrop={() => { if (!a.is_operator) handleDrop(a.agent_id); }}
                  className={`flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors cursor-pointer ${
                    !isNew && selectedId === a.agent_id
                      ? "bg-gray-800 text-white"
                      : "text-gray-400 hover:bg-gray-800/50"
                  } ${dragId === a.agent_id ? "opacity-40" : ""}`}
                  onClick={() => { setIsNew(false); setSelectedId(a.agent_id); }}
                >
                  {!a.is_operator && (
                    <span className="text-gray-600 cursor-grab active:cursor-grabbing select-none" title="Drag to reorder">
                      ⠿
                    </span>
                  )}
                  <span
                    className={`w-2 h-2 rounded-full flex-shrink-0 status-dot ${
                      a.status === "healthy"
                        ? "bg-green-500"
                        : a.status === "error"
                        ? "bg-red-500"
                        : "bg-blue-500"
                    }`}
                  />
                  <span className="truncate">
                    {a.is_operator && <span className="mr-1 text-xs">&#128274;</span>}
                    {a.name}
                  </span>
                </div>
              ))}
              <button
                onClick={() => { setIsNew(true); setSelectedId(null); }}
                className={`text-left px-3 py-2 rounded-lg text-sm transition-colors ${
                  isNew ? "bg-blue-900/50 text-blue-300" : "text-blue-500 hover:bg-gray-800/50"
                }`}
              >
                + New Agent
              </button>
            </div>

            {/* Right panel — edit form */}
            <div className="flex-1 overflow-y-auto p-6 space-y-6">
              {/* Name */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">Name</label>
                <input
                  value={form.name ?? ""}
                  onChange={(e) => setField("name", e.target.value)}
                  disabled={selected?.is_operator}
                  className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none
                             disabled:opacity-50 disabled:cursor-not-allowed"
                  placeholder="Agent name"
                />
              </div>

              {/* Health check */}
              {selected && (
                <div className="flex items-center gap-2 text-xs">
                  <span
                    className={`w-2 h-2 rounded-full status-dot ${
                      selected.status === "healthy"
                        ? "bg-green-500"
                        : selected.status === "error"
                        ? "bg-red-500"
                        : "bg-blue-500"
                    }`}
                  />
                  <span className="text-gray-400">
                    {selected.status === "healthy"
                      ? "Healthy"
                      : selected.status === "error"
                      ? selected.status_message || "Error"
                      : "Not checked"}
                  </span>
                  <button
                    onClick={async () => {
                      const res = await apiFetch(`/v1/agents/${selected.agent_id}/health-check`, { method: "POST" });
                      if (res.ok) onAgentsChanged();
                    }}
                    className="text-blue-400 hover:text-blue-300 ml-1"
                  >
                    Check now
                  </button>
                </div>
              )}

              {/* ── LLM Section ── */}
              <fieldset className="space-y-3">
                <legend className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
                  LLM Provider
                </legend>
                <select
                  value={form.llm_provider ?? "openai"}
                  onChange={(e) => setField("llm_provider", e.target.value)}
                  className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                >
                  {LLM_PROVIDER_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>{o.label}</option>
                  ))}
                </select>
                {llmSchema?.fields
                  .filter((f) => f.key !== "llm_model")
                  .map((field) => (
                    <div key={field.key}>
                      <label className="block text-xs text-gray-500 mb-1">{field.label}</label>
                      <input
                        type={field.type === "password" ? "password" : "text"}
                        value={form[field.key] ?? ""}
                        onChange={(e) => setField(field.key, e.target.value)}
                        placeholder={field.placeholder}
                        className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                      />
                    </div>
                  ))}
                <div>
                  <label className="block text-xs text-gray-500 mb-1">
                    {form.llm_provider === "ark" ? "Agent" : "Model"}
                  </label>
                  {llmModels.length > 0 ? (
                    <select
                      value={form.llm_model ?? ""}
                      onChange={(e) => setField("llm_model", e.target.value)}
                      className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                    >
                      {/* Allow current value even if it's no longer on the server,
                          so we don't silently drop it on save. */}
                      {form.llm_model && !llmModels.find((m) => m.id === form.llm_model) && (
                        <option value={form.llm_model}>{form.llm_model} (not on server)</option>
                      )}
                      <option value="" disabled>Select…</option>
                      {llmModels.map((m) => (
                        <option key={m.id} value={m.id}>
                          {m.description ? `${m.name} — ${m.description}` : m.name}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input
                      value={form.llm_model ?? ""}
                      onChange={(e) => setField("llm_model", e.target.value)}
                      placeholder={
                        llmSchema?.fields.find((f) => f.key === "llm_model")?.placeholder ?? "model"
                      }
                      className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                    />
                  )}
                </div>
              </fieldset>

              {/* ── TTS Section ── */}
              <fieldset className="space-y-3">
                <legend className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
                  TTS Provider
                </legend>
                <select
                  value={form.tts_provider ?? "none"}
                  onChange={(e) => setField("tts_provider", e.target.value)}
                  className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                >
                  {TTS_PROVIDER_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>{o.label}</option>
                  ))}
                </select>
                {ttsSchema?.fields.map((field) => (
                  <div key={field.key}>
                    <label className="block text-xs text-gray-500 mb-1">{field.label}</label>
                    {field.type === "select" && field.options ? (
                      <select
                        value={form[field.key] ?? field.options[0]?.value ?? ""}
                        onChange={(e) => setField(field.key, e.target.value)}
                        className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                      >
                        {field.options.map((opt) => (
                          <option key={opt.value} value={opt.value}>{opt.label}</option>
                        ))}
                      </select>
                    ) : (
                      <input
                        type={field.type === "password" ? "password" : "text"}
                        value={form[field.key] ?? ""}
                        onChange={(e) => setField(field.key, e.target.value)}
                        placeholder={field.placeholder}
                        className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                      />
                    )}
                  </div>
                ))}
                {ttsModels.length > 0 && (
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">TTS Model</label>
                    <select
                      value={form.model ?? "tts-1"}
                      onChange={(e) => setField("model", e.target.value)}
                      className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                    >
                      {ttsModels.map((m) => (
                        <option key={m.id} value={m.id}>{m.name}</option>
                      ))}
                    </select>
                  </div>
                )}
                {ttsProvider !== "none" && (
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Voice</label>
                    <select
                      value={form.voice_id ?? ""}
                      onChange={(e) => setField("voice_id", e.target.value)}
                      disabled={voices.length === 0}
                      className={`w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none ${
                        voices.length === 0 ? "opacity-50 cursor-not-allowed" : ""
                      }`}
                    >
                      {voices.length === 0 ? (
                        <option value="">No voices available — check API key</option>
                      ) : (
                        <>
                          <option value="">Select voice…</option>
                          {voices.map((v) => (
                            <option key={v.id} value={v.id}>
                              {v.name} — {v.description}
                            </option>
                          ))}
                        </>
                      )}
                    </select>
                  </div>
                )}
                {ttsProvider === "openai" && (
                  <>
                    <div>
                      <label className="flex justify-between text-xs text-gray-500 mb-1">
                        <span>Speed</span>
                        <span>{parseFloat(form.speed || "1").toFixed(2)}</span>
                      </label>
                      <input
                        type="range"
                        min={0.25}
                        max={4.0}
                        step={0.25}
                        value={parseFloat(form.speed || "1")}
                        onChange={(e) => setField("speed", e.target.value)}
                        className="w-full accent-blue-500"
                      />
                    </div>
                  </>
                )}
                {ttsProvider === "elevenlabs" && (
                  <>
                    <div>
                      <label className="block text-xs text-gray-500 mb-1">Model</label>
                      <select
                        value={form.model_id ?? "eleven_multilingual_v2"}
                        onChange={(e) => setField("model_id", e.target.value)}
                        className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                      >
                        <option value="eleven_multilingual_v2">Multilingual v2</option>
                        <option value="eleven_turbo_v2_5">Turbo v2.5</option>
                        <option value="eleven_flash_v2_5">Flash v2.5</option>
                      </select>
                    </div>
                    <div>
                      <label className="flex justify-between text-xs text-gray-500 mb-1">
                        <span>Stability</span>
                        <span>{parseFloat(form.stability || "0.5").toFixed(2)}</span>
                      </label>
                      <input
                        type="range"
                        min={0}
                        max={1}
                        step={0.05}
                        value={parseFloat(form.stability || "0.5")}
                        onChange={(e) => setField("stability", e.target.value)}
                        className="w-full accent-blue-500"
                      />
                    </div>
                    <div>
                      <label className="flex justify-between text-xs text-gray-500 mb-1">
                        <span>Similarity Boost</span>
                        <span>{parseFloat(form.similarity_boost || "0.75").toFixed(2)}</span>
                      </label>
                      <input
                        type="range"
                        min={0}
                        max={1}
                        step={0.05}
                        value={parseFloat(form.similarity_boost || "0.75")}
                        onChange={(e) => setField("similarity_boost", e.target.value)}
                        className="w-full accent-blue-500"
                      />
                    </div>
                  </>
                )}
              </fieldset>

              {/* ── Persona ── */}
              <div>
                <label className="block text-xs text-gray-500 mb-1">Persona Prompt</label>
                <textarea
                  value={form.persona_prompt ?? ""}
                  onChange={(e) => setField("persona_prompt", e.target.value)}
                  rows={4}
                  className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none resize-y"
                  placeholder="System prompt for this agent…"
                />
              </div>

              {/* ── Actions ── */}
              <div className="flex items-center gap-3 pt-2">
                <button
                  onClick={handleSave}
                  disabled={saving}
                  className="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 rounded-lg px-4 py-2
                             text-sm font-medium transition-colors"
                  style={currentTheme !== "default" ? { backgroundColor: "var(--primary)", color: "var(--bg)" } : undefined}
                >
                  {saving ? "Saving…" : isNew ? "Create Agent" : "Save Changes"}
                </button>
                {selected && !selected.is_operator && (
                  <button
                    onClick={handleDelete}
                    disabled={deleting}
                    className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
                      confirmDelete
                        ? "bg-red-600 hover:bg-red-500"
                        : "bg-gray-700 hover:bg-gray-600 text-red-400"
                    }`}
                  >
                    {deleting
                      ? "Deleting…"
                      : confirmDelete
                      ? "Confirm Delete"
                      : "Delete Agent"}
                  </button>
                )}
              </div>
            </div>
          </div>
        )}

        {/* ════════ Text to Speech Tab ════════ */}
        {tab === "tts" && (
          <div className="flex-1 overflow-y-auto p-6 space-y-6 max-w-2xl">
            {/* Default Provider */}
            <fieldset className="space-y-3">
              <legend className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
                Default Provider
              </legend>
              <select
                value={platformForm.tts_default_provider ?? "none"}
                onChange={(e) =>
                  setPlatformForm((f) => ({ ...f, tts_default_provider: e.target.value }))
                }
                className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
              >
                <option value="none">None</option>
                <option value="openai">OpenAI</option>
                <option value="elevenlabs">ElevenLabs</option>
              </select>
              <p className="text-xs text-gray-600">
                The default TTS provider used when agents do not specify their own.
              </p>
            </fieldset>

            {/* OpenAI TTS */}
            <fieldset className="space-y-3">
              <legend className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
                OpenAI TTS
              </legend>
              <div>
                <label className="block text-xs text-gray-500 mb-1">API Key</label>
                <input
                  type="password"
                  value={platformForm.tts_openai_api_key ?? ""}
                  onChange={(e) =>
                    setPlatformForm((f) => ({ ...f, tts_openai_api_key: e.target.value }))
                  }
                  placeholder={
                    platform?.tts_openai_api_key
                      ? `${platform.tts_openai_api_key} (leave blank to keep)`
                      : "sk-… (falls back to env var)"
                  }
                  className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                />
              </div>
              <p className="text-xs text-gray-600">
                Platform-wide OpenAI API key for text-to-speech. Agents without their own key will fall back to this.
              </p>
            </fieldset>

            {/* ElevenLabs */}
            <fieldset className="space-y-3">
              <legend className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
                ElevenLabs
              </legend>
              <div>
                <label className="block text-xs text-gray-500 mb-1">API Key</label>
                <input
                  type="password"
                  value={platformForm.tts_elevenlabs_api_key ?? ""}
                  onChange={(e) =>
                    setPlatformForm((f) => ({ ...f, tts_elevenlabs_api_key: e.target.value }))
                  }
                  placeholder={
                    platform?.tts_elevenlabs_api_key
                      ? `${platform.tts_elevenlabs_api_key} (leave blank to keep)`
                      : "xi-… (falls back to env var)"
                  }
                  className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                />
              </div>
              <p className="text-xs text-gray-600">
                Platform-wide ElevenLabs API key for text-to-speech. Agents without their own key will fall back to this.
              </p>
            </fieldset>

            <button
              onClick={handleSaveTtsPlatform}
              disabled={savingPlatform}
              className="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 rounded-lg px-4 py-2
                         text-sm font-medium transition-colors"
              style={currentTheme !== "default" ? { backgroundColor: "var(--primary)", color: "var(--bg)" } : undefined}
            >
              {savingPlatform ? "Saving…" : "Save Settings"}
            </button>
          </div>
        )}

        {/* ════════ Speech to Text Tab ════════ */}
        {tab === "stt" && (
          <div className="flex-1 flex flex-col min-h-0 max-w-2xl">
          <div className="flex-1 overflow-y-auto p-6 space-y-6">
            {/* STT Provider */}
            <fieldset className="space-y-3">
              <legend className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
                Provider
              </legend>
              <select
                value={platformForm.stt_provider ?? "openai"}
                onChange={(e) =>
                  setPlatformForm((f) => ({ ...f, stt_provider: e.target.value }))
                }
                className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
              >
                {STT_PROVIDER_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>{o.label}</option>
                ))}
              </select>
              <div>
                <label className="block text-xs text-gray-500 mb-1">API Key</label>
                <input
                  type="password"
                  value={platformForm.stt_api_key ?? ""}
                  onChange={(e) =>
                    setPlatformForm((f) => ({ ...f, stt_api_key: e.target.value }))
                  }
                  placeholder={
                    (platformForm.stt_provider ?? "openai") === "elevenlabs"
                      ? "xi-… (falls back to TTS ElevenLabs key, then env var)"
                      : "sk-… (falls back to env var)"
                  }
                  className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
                />
              </div>
            </fieldset>

            {/* Recognition Tuning */}
            <fieldset className="space-y-4">
              <legend className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
                Recognition Tuning
              </legend>
              <p className="text-xs text-gray-600">
                Adjust these to reduce false transcriptions from ambient noise.
              </p>

              {/* Silence Threshold */}
              <div>
                <label className="flex justify-between text-xs text-gray-500 mb-1">
                  <span>Silence Threshold</span>
                  <span>{parseFloat(platformForm.stt_silence_threshold_db || "-35")} dB</span>
                </label>
                <input
                  type="range"
                  min={-50}
                  max={-10}
                  step={1}
                  value={parseFloat(platformForm.stt_silence_threshold_db || "-35")}
                  onChange={(e) =>
                    setPlatformForm((f) => ({ ...f, stt_silence_threshold_db: e.target.value }))
                  }
                  className="w-full accent-blue-500"
                />
                <p className="text-xs text-gray-600 mt-1">
                  Minimum dB level to detect speech. Higher = less sensitive to noise.
                </p>
              </div>

              {/* Silence Timeout */}
              <div>
                <label className="flex justify-between text-xs text-gray-500 mb-1">
                  <span>Silence Timeout</span>
                  <span>{platformForm.stt_silence_timeout_ms || "500"} ms</span>
                </label>
                <input
                  type="range"
                  min={200}
                  max={2000}
                  step={50}
                  value={parseInt(platformForm.stt_silence_timeout_ms || "500")}
                  onChange={(e) =>
                    setPlatformForm((f) => ({ ...f, stt_silence_timeout_ms: e.target.value }))
                  }
                  className="w-full accent-blue-500"
                />
                <p className="text-xs text-gray-600 mt-1">
                  How long silence must last before ending a recording.
                </p>
              </div>

              {/* Min Duration */}
              <div>
                <label className="flex justify-between text-xs text-gray-500 mb-1">
                  <span>Min Duration</span>
                  <span>{platformForm.stt_min_duration_ms || "400"} ms</span>
                </label>
                <input
                  type="range"
                  min={200}
                  max={1000}
                  step={50}
                  value={parseInt(platformForm.stt_min_duration_ms || "400")}
                  onChange={(e) =>
                    setPlatformForm((f) => ({ ...f, stt_min_duration_ms: e.target.value }))
                  }
                  className="w-full accent-blue-500"
                />
                <p className="text-xs text-gray-600 mt-1">
                  Recordings shorter than this are discarded.
                </p>
              </div>

              {/* No-Speech Threshold (OpenAI / Whisper only) */}
              {(platformForm.stt_provider ?? "openai") === "openai" && (
              <div>
                <label className="flex justify-between text-xs text-gray-500 mb-1">
                  <span>No-Speech Filter</span>
                  <span>{parseFloat(platformForm.stt_no_speech_threshold || "0.5").toFixed(2)}</span>
                </label>
                <input
                  type="range"
                  min={0.1}
                  max={0.9}
                  step={0.05}
                  value={parseFloat(platformForm.stt_no_speech_threshold || "0.5")}
                  onChange={(e) =>
                    setPlatformForm((f) => ({ ...f, stt_no_speech_threshold: e.target.value }))
                  }
                  className="w-full accent-blue-500"
                />
                <p className="text-xs text-gray-600 mt-1">
                  Whisper segments with no-speech probability above this are filtered. Lower = stricter.
                </p>
              </div>
              )}
            </fieldset>
          </div>
          <div className="p-6 pt-2 border-t border-gray-800">
            <button
              onClick={handleSavePlatform}
              disabled={savingPlatform}
              className="bg-blue-600 hover:bg-blue-500 disabled:opacity-50 rounded-lg px-4 py-2
                         text-sm font-medium transition-colors"
              style={currentTheme !== "default" ? { backgroundColor: "var(--primary)", color: "var(--bg)" } : undefined}
            >
              {savingPlatform ? "Saving…" : "Save Settings"}
            </button>
          </div>
          </div>
        )}
        {/* ════════ Appearance Tab ════════ */}
        {tab === "appearance" && (
          <div className="flex-1 overflow-y-auto p-6 space-y-6">
            <div>
              <h3 className="text-sm font-semibold text-gray-400 uppercase tracking-wider mb-4">Theme</h3>
              <div className="flex gap-3">
                {(["default", "light", "tva", "tva_mono", "retro_green"] as ThemeName[]).map((name) => (
                  <button
                    key={name}
                    onClick={() => {
                      applyTheme(name);
                      setCurrentTheme(name);
                    }}
                    className={`px-6 py-3 rounded-lg text-sm font-medium transition-colors border ${
                      currentTheme === name
                        ? "bg-gray-700 text-white border-gray-500"
                        : "bg-gray-900 text-gray-400 border-gray-800 hover:bg-gray-800"
                    }`}
                  >
                    {{ default: "Default", light: "Light", tva: "TVA", tva_mono: "TVA Mono", retro_green: "Retro Green" }[name]}
                  </button>
                ))}
              </div>
              <p className="text-xs text-gray-600 mt-3">
                {currentTheme === "tva_mono"
                  ? "FOR ALL TIME. ALWAYS."
                  : currentTheme === "tva"
                  ? "FOR ALL TIME. ALWAYS."
                  : currentTheme === "light"
                  ? "Bright and clean."
                  : currentTheme === "retro_green"
                  ? "Phosphor on glass."
                  : "The standard Relay experience."}
              </p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
