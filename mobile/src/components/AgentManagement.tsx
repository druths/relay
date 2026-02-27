import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Modal,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import Slider from "@react-native-community/slider";
import { Ionicons } from "@expo/vector-icons";
import type { Agent, PlatformSettings } from "../types";
import {
  LLM_PROVIDERS,
  TTS_PROVIDERS,
  LLM_PROVIDER_OPTIONS,
  TTS_PROVIDER_OPTIONS,
  STT_PROVIDER_OPTIONS,
} from "../providerSchemas";
import { apiFetch } from "../apiFetch";

interface Voice {
  id: string;
  name: string;
  description: string;
}

interface Props {
  agents: Agent[];
  visible: boolean;
  onClose: () => void;
  onAgentsChanged: () => void;
}

type Tab = "agents" | "tts" | "stt";

export function AgentManagement({ agents, visible, onClose, onAgentsChanged }: Props) {
  const [tab, setTab] = useState<Tab>("agents");

  // ── Agent state ──
  const sorted = [...agents].sort((a, b) => {
    if (a.is_operator) return -1;
    if (b.is_operator) return 1;
    return a.name.localeCompare(b.name);
  });

  const [selectedId, setSelectedId] = useState<string | null>(
    sorted[0]?.agent_id ?? null
  );
  const [isNew, setIsNew] = useState(false);
  const [form, setForm] = useState<Record<string, string | null>>({});
  const [saving, setSaving] = useState(false);
  const [voices, setVoices] = useState<Voice[]>([]);

  // ── Platform settings state ──
  const [platform, setPlatform] = useState<PlatformSettings | null>(null);
  const [platformForm, setPlatformForm] = useState<Record<string, string>>({});
  const [savingPlatform, setSavingPlatform] = useState(false);

  const selected = isNew ? null : agents.find((a) => a.agent_id === selectedId);

  // Load platform settings
  useEffect(() => {
    if (!visible) return;
    apiFetch("/v1/platform/settings")
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
  }, [visible]);

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
        model_id: String(selected.voice_settings?.model_id ?? "eleven_multilingual_v2"),
        stability: String(selected.voice_settings?.stability ?? 0.5),
        similarity_boost: String(selected.voice_settings?.similarity_boost ?? 0.75),
      });
    }
  }, [selectedId, isNew, selected?.agent_id]);

  // Fetch voices when TTS provider or API key changes
  const ttsProvider = form.tts_provider ?? "none";
  const ttsFormKey = form.tts_api_key ?? "";
  useEffect(() => {
    if (ttsProvider === "none") { setVoices([]); return; }
    const isRealKey = ttsFormKey && !ttsFormKey.includes("\u2022");
    const keyParam = isRealKey ? `?api_key=${encodeURIComponent(ttsFormKey)}` : "" ;
    const timer = setTimeout(() => {
      apiFetch(`/v1/agents/tts/voices/${ttsProvider}${keyParam}`)
        .then((r) => r.json())
        .then((data: Voice[]) => setVoices(data))
        .catch(() => setVoices([]));
    }, 300);
    return () => clearTimeout(timer);
  }, [ttsProvider, ttsFormKey]);

  const setField = (key: string, value: string) =>
    setForm((f) => ({ ...f, [key]: value }));

  // ── Save agent ──
  const handleSave = async () => {
    setSaving(true);
    try {
      if (isNew) {
        let voice_settings: Record<string, unknown> = {};
        if (form.tts_provider === "openai") {
          voice_settings = { speed: parseFloat(form.speed || "1"), model: form.model || "tts-1" };
        } else if (form.tts_provider === "elevenlabs") {
          voice_settings = { stability: parseFloat(form.stability || "0.5"), similarity_boost: parseFloat(form.similarity_boost || "0.75"), model_id: form.model_id || "eleven_multilingual_v2" };
        }
        const body: Record<string, unknown> = {
          name: form.name, persona_prompt: form.persona_prompt ?? "",
          llm_provider: form.llm_provider, llm_model: form.llm_model,
          llm_base_url: form.llm_base_url || null, llm_api_key: form.llm_api_key || null,
          tts_provider: form.tts_provider || "none", tts_api_key: form.tts_api_key || null,
          voice_id: form.voice_id || "", voice_settings,
        };
        const res = await apiFetch("/v1/agents", {
          method: "POST", body: JSON.stringify(body),
        });
        if (!res.ok) throw new Error(await res.text());
        const created: Agent = await res.json();
        setIsNew(false);
        setSelectedId(created.agent_id);
      } else if (selected) {
        let voice_settings: Record<string, unknown> = {};
        if (form.tts_provider === "openai") {
          voice_settings = { speed: parseFloat(form.speed || "1"), model: form.model || "tts-1" };
        } else if (form.tts_provider === "elevenlabs") {
          voice_settings = { stability: parseFloat(form.stability || "0.5"), similarity_boost: parseFloat(form.similarity_boost || "0.75"), model_id: form.model_id || "eleven_multilingual_v2" };
        }
        const body: Record<string, unknown> = {
          persona_prompt: form.persona_prompt, llm_provider: form.llm_provider, llm_model: form.llm_model,
          llm_base_url: form.llm_base_url || "", tts_provider: form.tts_provider || "none",
          voice_id: form.voice_id || "", voice_settings,
        };
        if (!selected.is_operator && form.name !== selected.name) body.name = form.name;
        // API keys: send only if changed from the masked original.
        // Empty string clears the key (falls back to platform default).
        if (form.llm_api_key !== (selected.llm_api_key ?? "")) {
          body.llm_api_key = form.llm_api_key;
        }
        if (form.tts_api_key !== (selected.tts_api_key ?? "")) {
          body.tts_api_key = form.tts_api_key;
        }
        const res = await apiFetch(`/v1/agents/${selected.agent_id}/config`, {
          method: "PATCH", body: JSON.stringify(body),
        });
        if (!res.ok) throw new Error(await res.text());
      }
      onAgentsChanged();
    } catch (err) { Alert.alert("Error", String(err)); }
    finally { setSaving(false); }
  };

  // ── Delete agent ──
  const handleDelete = () => {
    if (!selected || selected.is_operator) return;
    Alert.alert("Delete Agent", `Are you sure you want to delete "${selected.name}"?`, [
      { text: "Cancel", style: "cancel" },
      { text: "Delete", style: "destructive", onPress: async () => {
        try {
          const res = await apiFetch(`/v1/agents/${selected.agent_id}`, { method: "DELETE" });
          if (!res.ok) throw new Error(await res.text());
          setSelectedId(sorted[0]?.agent_id ?? null);
          onAgentsChanged();
        } catch (err) { Alert.alert("Error", String(err)); }
      }},
    ]);
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
      if (platformForm.tts_default_provider) body.tts_default_provider = platformForm.tts_default_provider;
      if (platformForm.tts_openai_api_key) body.tts_openai_api_key = platformForm.tts_openai_api_key;
      if (platformForm.tts_elevenlabs_api_key) body.tts_elevenlabs_api_key = platformForm.tts_elevenlabs_api_key;
      const res = await apiFetch("/v1/platform/settings", {
        method: "PATCH", body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(await res.text());
      const updated: PlatformSettings = await res.json();
      setPlatform(updated);
      setPlatformForm((f) => ({
        ...f, stt_api_key: updated.stt_api_key ?? "",
        stt_silence_threshold_db: String(updated.stt_silence_threshold_db),
        stt_silence_timeout_ms: String(updated.stt_silence_timeout_ms),
        stt_min_duration_ms: String(updated.stt_min_duration_ms),
        stt_no_speech_threshold: String(updated.stt_no_speech_threshold),
        tts_default_provider: updated.tts_default_provider ?? "none",
        tts_openai_api_key: "",
        tts_elevenlabs_api_key: "",
      }));
    } catch (err) { Alert.alert("Error", String(err)); }
    finally { setSavingPlatform(false); }
  };

  const llmSchema = LLM_PROVIDERS[form.llm_provider ?? "openai"];
  const ttsSchema = TTS_PROVIDERS[form.tts_provider ?? "none"];

  const showPicker = useCallback(
    (title: string, options: { value: string; label: string }[], current: string, onSelect: (value: string) => void) => {
      Alert.alert(title, undefined, [
        ...options.map((o) => ({
          text: o.value === current ? `${o.label} ✓` : o.label,
          onPress: () => onSelect(o.value),
        })),
        { text: "Cancel", style: "cancel" as const },
      ]);
    }, []
  );

  return (
    <Modal visible={visible} animationType="slide" presentationStyle="fullScreen">
      <View style={st.container}>
        {/* Header */}
        <View style={st.header}>
          <Text style={st.headerTitle}>Settings</Text>
          <TouchableOpacity onPress={onClose} hitSlop={12}>
            <Ionicons name="close" size={24} color="#9ca3af" />
          </TouchableOpacity>
        </View>

        {/* Tab bar */}
        <View style={st.tabBar}>
          <TouchableOpacity
            style={[st.tabBtn, tab === "agents" && st.tabBtnActive]}
            onPress={() => setTab("agents")}
          >
            <Text style={[st.tabBtnText, tab === "agents" && st.tabBtnTextActive]}>Agents</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[st.tabBtn, tab === "tts" && st.tabBtnActive]}
            onPress={() => setTab("tts")}
          >
            <Text style={[st.tabBtnText, tab === "tts" && st.tabBtnTextActive]}>Text to Speech</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[st.tabBtn, tab === "stt" && st.tabBtnActive]}
            onPress={() => setTab("stt")}
          >
            <Text style={[st.tabBtnText, tab === "stt" && st.tabBtnTextActive]}>Speech to Text</Text>
          </TouchableOpacity>
        </View>

        {/* ════════ Agents Tab ════════ */}
        {tab === "agents" && (
          <>
            {/* Agent picker */}
            <View style={st.agentPicker}>
              <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={st.agentPickerContent}>
                {sorted.map((a) => {
                  const active = !isNew && selectedId === a.agent_id;
                  return (
                    <TouchableOpacity key={a.agent_id} onPress={() => { setIsNew(false); setSelectedId(a.agent_id); }}
                      style={[st.pill, active && st.pillActive]}>
                      <View style={[st.dot, a.status === "healthy" ? st.dotHealthy : a.status === "error" ? st.dotError : st.dotUnknown]} />
                      {a.is_operator && <Ionicons name="lock-closed" size={10} color="#6b7280" style={{ marginRight: 2 }} />}
                      <Text style={[st.pillText, active && st.pillTextActive]}>{a.name}</Text>
                    </TouchableOpacity>
                  );
                })}
                <TouchableOpacity onPress={() => { setIsNew(true); setSelectedId(null); }} style={[st.pill, isNew && st.pillNew]}>
                  <Ionicons name="add" size={14} color={isNew ? "#93c5fd" : "#3b82f6"} />
                  <Text style={[st.pillText, { color: isNew ? "#93c5fd" : "#3b82f6" }]}>New</Text>
                </TouchableOpacity>
              </ScrollView>
            </View>

            {/* Agent form */}
            <ScrollView style={st.body} contentContainerStyle={st.bodyContent} keyboardShouldPersistTaps="handled">
              {selected && (
                <View style={st.healthRow}>
                  <View style={[st.dot, selected.status === "healthy" ? st.dotHealthy : selected.status === "error" ? st.dotError : st.dotUnknown]} />
                  <Text style={st.healthText}>{selected.status === "healthy" ? "Healthy" : selected.status === "error" ? selected.status_message || "Error" : "Unknown"}</Text>
                </View>
              )}

              <Text style={st.label}>Name</Text>
              <TextInput style={[st.input, selected?.is_operator && st.inputDisabled]} value={form.name ?? ""} onChangeText={(v) => setField("name", v)}
                editable={!selected?.is_operator} placeholder="Agent name" placeholderTextColor="#4b5563" />

              <Text style={st.sectionTitle}>LLM PROVIDER</Text>
              <TouchableOpacity style={st.picker} onPress={() => showPicker("LLM Provider", LLM_PROVIDER_OPTIONS, form.llm_provider ?? "openai", (v) => setField("llm_provider", v))}>
                <Text style={st.pickerText}>{LLM_PROVIDERS[form.llm_provider ?? "openai"]?.label ?? form.llm_provider}</Text>
                <Ionicons name="chevron-down" size={16} color="#6b7280" />
              </TouchableOpacity>

              {llmSchema?.fields.filter((f) => f.key !== "llm_model").map((field) => (
                <View key={field.key}>
                  <Text style={st.label}>{field.label}</Text>
                  <TextInput style={st.input} value={form[field.key] ?? ""} onChangeText={(v) => setField(field.key, v)}
                    secureTextEntry={field.type === "password"} autoCapitalize="none" autoCorrect={false}
                    placeholder={field.placeholder}
                    placeholderTextColor="#4b5563" />
                </View>
              ))}

              <Text style={st.label}>Model</Text>
              <TextInput style={st.input} value={form.llm_model ?? ""} onChangeText={(v) => setField("llm_model", v)}
                autoCapitalize="none" autoCorrect={false}
                placeholder={llmSchema?.fields.find((f) => f.key === "llm_model")?.placeholder ?? "model"} placeholderTextColor="#4b5563" />

              <Text style={st.sectionTitle}>TTS PROVIDER</Text>
              <TouchableOpacity style={st.picker} onPress={() => showPicker("TTS Provider", TTS_PROVIDER_OPTIONS, form.tts_provider ?? "none", (v) => setField("tts_provider", v))}>
                <Text style={st.pickerText}>{TTS_PROVIDERS[form.tts_provider ?? "none"]?.label ?? form.tts_provider}</Text>
                <Ionicons name="chevron-down" size={16} color="#6b7280" />
              </TouchableOpacity>

              {ttsSchema?.fields.map((field) => (
                <View key={field.key}>
                  <Text style={st.label}>{field.label}</Text>
                  <TextInput style={st.input} value={form[field.key] ?? ""} onChangeText={(v) => setField(field.key, v)}
                    secureTextEntry={field.type === "password"} autoCapitalize="none" autoCorrect={false}
                    placeholder={field.placeholder}
                    placeholderTextColor="#4b5563" />
                </View>
              ))}

              {ttsProvider !== "none" && (
                <View>
                  <Text style={st.label}>Voice</Text>
                  <TouchableOpacity
                    style={[st.picker, voices.length === 0 && { opacity: 0.5 }]}
                    disabled={voices.length === 0}
                    onPress={() => showPicker("Voice",
                      voices.map((v) => ({ value: v.id, label: `${v.name} — ${v.description}` })),
                      form.voice_id ?? "", (v) => setField("voice_id", v))}
                  >
                    <Text style={st.pickerText} numberOfLines={1}>
                      {voices.length === 0
                        ? "No voices available — check API key"
                        : voices.find((v) => v.id === form.voice_id)?.name || "Select voice…"}
                    </Text>
                    <Ionicons name="chevron-down" size={16} color="#6b7280" />
                  </TouchableOpacity>
                </View>
              )}

              {ttsProvider === "openai" && (
                <View>
                  <Text style={st.label}>Model</Text>
                  <TouchableOpacity style={st.picker} onPress={() => showPicker("OpenAI TTS Model",
                    [{ value: "tts-1", label: "tts-1" }, { value: "tts-1-hd", label: "tts-1-hd" }],
                    form.model ?? "tts-1", (v) => setField("model", v))}>
                    <Text style={st.pickerText}>{form.model || "tts-1"}</Text>
                    <Ionicons name="chevron-down" size={16} color="#6b7280" />
                  </TouchableOpacity>

                  <View style={st.sliderLabel}>
                    <Text style={st.label}>Speed</Text>
                    <Text style={st.label}>{parseFloat(form.speed || "1").toFixed(2)}</Text>
                  </View>
                  <Slider minimumValue={0.25} maximumValue={4.0} step={0.25} value={parseFloat(form.speed || "1")}
                    onValueChange={(v) => setField("speed", String(v))}
                    minimumTrackTintColor="#2563eb" maximumTrackTintColor="#374151" thumbTintColor="#2563eb" style={st.slider} />
                </View>
              )}

              {ttsProvider === "elevenlabs" && (
                <View>
                  <Text style={st.label}>Model</Text>
                  <TouchableOpacity style={st.picker} onPress={() => showPicker("ElevenLabs Model",
                    [
                      { value: "eleven_multilingual_v2", label: "eleven_multilingual_v2" },
                      { value: "eleven_turbo_v2_5", label: "eleven_turbo_v2_5" },
                      { value: "eleven_flash_v2_5", label: "eleven_flash_v2_5" },
                    ],
                    form.model_id ?? "eleven_multilingual_v2", (v) => setField("model_id", v))}>
                    <Text style={st.pickerText}>{form.model_id || "eleven_multilingual_v2"}</Text>
                    <Ionicons name="chevron-down" size={16} color="#6b7280" />
                  </TouchableOpacity>

                  <View style={st.sliderLabel}>
                    <Text style={st.label}>Stability</Text>
                    <Text style={st.label}>{parseFloat(form.stability || "0.5").toFixed(2)}</Text>
                  </View>
                  <Slider minimumValue={0} maximumValue={1} step={0.05} value={parseFloat(form.stability || "0.5")}
                    onValueChange={(v) => setField("stability", String(v))}
                    minimumTrackTintColor="#2563eb" maximumTrackTintColor="#374151" thumbTintColor="#2563eb" style={st.slider} />

                  <View style={st.sliderLabel}>
                    <Text style={st.label}>Similarity Boost</Text>
                    <Text style={st.label}>{parseFloat(form.similarity_boost || "0.75").toFixed(2)}</Text>
                  </View>
                  <Slider minimumValue={0} maximumValue={1} step={0.05} value={parseFloat(form.similarity_boost || "0.75")}
                    onValueChange={(v) => setField("similarity_boost", String(v))}
                    minimumTrackTintColor="#2563eb" maximumTrackTintColor="#374151" thumbTintColor="#2563eb" style={st.slider} />
                </View>
              )}

              <Text style={st.label}>Persona Prompt</Text>
              <TextInput style={[st.input, st.textArea]} value={form.persona_prompt ?? ""} onChangeText={(v) => setField("persona_prompt", v)}
                multiline numberOfLines={4} textAlignVertical="top" placeholder="System prompt for this agent…" placeholderTextColor="#4b5563" />

              <View style={st.actions}>
                <TouchableOpacity style={[st.saveBtn, saving && st.btnDisabled]} onPress={handleSave} disabled={saving}>
                  <Text style={st.saveBtnText}>{saving ? "Saving…" : isNew ? "Create Agent" : "Save Changes"}</Text>
                </TouchableOpacity>
                {selected && !selected.is_operator && (
                  <TouchableOpacity style={st.deleteBtn} onPress={handleDelete}>
                    <Text style={st.deleteBtnText}>Delete</Text>
                  </TouchableOpacity>
                )}
              </View>

              <View style={{ height: 40 }} />
            </ScrollView>
          </>
        )}

        {/* ════════ Text to Speech Tab ════════ */}
        {tab === "tts" && (
          <ScrollView style={st.body} contentContainerStyle={st.bodyContent} keyboardShouldPersistTaps="handled">
            <Text style={st.sectionTitle}>DEFAULT PROVIDER</Text>
            <TouchableOpacity style={st.picker} onPress={() => showPicker("Default TTS Provider",
              [
                { value: "none", label: "None" },
                { value: "openai", label: "OpenAI" },
                { value: "elevenlabs", label: "ElevenLabs" },
              ],
              platformForm.tts_default_provider ?? "none",
              (v) => setPlatformForm((f) => ({ ...f, tts_default_provider: v })))}>
              <Text style={st.pickerText}>
                {platformForm.tts_default_provider === "openai" ? "OpenAI"
                  : platformForm.tts_default_provider === "elevenlabs" ? "ElevenLabs"
                  : "None"}
              </Text>
              <Ionicons name="chevron-down" size={16} color="#6b7280" />
            </TouchableOpacity>
            <Text style={st.hint}>The default TTS provider used when creating new agents.</Text>

            <View style={st.separator} />
            <Text style={st.sectionTitle}>OPENAI TTS</Text>
            <Text style={st.label}>API Key</Text>
            <TextInput style={st.input} value={platformForm.tts_openai_api_key ?? ""}
              onChangeText={(v) => setPlatformForm((f) => ({ ...f, tts_openai_api_key: v }))}
              secureTextEntry autoCapitalize="none" autoCorrect={false}
              placeholder={platform?.tts_openai_api_key ? `${platform.tts_openai_api_key} (leave blank to keep)` : "sk-… (falls back to env var)"}
              placeholderTextColor="#4b5563" />
            <Text style={st.hint}>Platform-wide OpenAI API key for text-to-speech. Individual agents can override this with their own key.</Text>

            <View style={st.separator} />
            <Text style={st.sectionTitle}>ELEVENLABS</Text>
            <Text style={st.label}>API Key</Text>
            <TextInput style={st.input} value={platformForm.tts_elevenlabs_api_key ?? ""}
              onChangeText={(v) => setPlatformForm((f) => ({ ...f, tts_elevenlabs_api_key: v }))}
              secureTextEntry autoCapitalize="none" autoCorrect={false}
              placeholder={platform?.tts_elevenlabs_api_key ? `${platform.tts_elevenlabs_api_key} (leave blank to keep)` : "xi-… (falls back to env var)"}
              placeholderTextColor="#4b5563" />
            <Text style={st.hint}>Platform-wide ElevenLabs API key for text-to-speech. Individual agents can override this with their own key.</Text>

            <TouchableOpacity style={[st.saveBtn, savingPlatform && st.btnDisabled, { marginTop: 20 }]}
              onPress={handleSavePlatform} disabled={savingPlatform}>
              <Text style={st.saveBtnText}>{savingPlatform ? "Saving…" : "Save Settings"}</Text>
            </TouchableOpacity>

            <View style={{ height: 40 }} />
          </ScrollView>
        )}

        {/* ════════ Speech to Text Tab ════════ */}
        {tab === "stt" && (
          <ScrollView style={st.body} contentContainerStyle={st.bodyContent} keyboardShouldPersistTaps="handled">
            <Text style={st.sectionTitle}>PROVIDER</Text>
            <TouchableOpacity style={st.picker} onPress={() => showPicker("STT Provider",
              STT_PROVIDER_OPTIONS,
              platformForm.stt_provider ?? "openai",
              (v) => setPlatformForm((f) => ({ ...f, stt_provider: v })))}>
              <Text style={st.pickerText}>{STT_PROVIDER_OPTIONS.find((o) => o.value === (platformForm.stt_provider ?? "openai"))?.label ?? platformForm.stt_provider}</Text>
              <Ionicons name="chevron-down" size={16} color="#6b7280" />
            </TouchableOpacity>

            <Text style={st.label}>API Key</Text>
            <TextInput style={st.input} value={platformForm.stt_api_key ?? ""}
              onChangeText={(v) => setPlatformForm((f) => ({ ...f, stt_api_key: v }))}
              secureTextEntry autoCapitalize="none" autoCorrect={false}
              placeholder={(platformForm.stt_provider ?? "openai") === "elevenlabs" ? "xi-… (falls back to TTS ElevenLabs key)" : "sk-… (falls back to env var)"}
              placeholderTextColor="#4b5563" />

            <View style={st.separator} />
            <Text style={st.sectionTitle}>RECOGNITION TUNING</Text>
            <Text style={st.hint}>Adjust these to reduce false transcriptions from ambient noise.</Text>

            {/* Silence Threshold */}
            <View style={st.sliderLabel}>
              <Text style={st.label}>Silence Threshold</Text>
              <Text style={st.label}>{parseFloat(platformForm.stt_silence_threshold_db || "-35")} dB</Text>
            </View>
            <Slider minimumValue={-50} maximumValue={-10} step={1}
              value={parseFloat(platformForm.stt_silence_threshold_db || "-35")}
              onValueChange={(v) => setPlatformForm((f) => ({ ...f, stt_silence_threshold_db: String(v) }))}
              minimumTrackTintColor="#2563eb" maximumTrackTintColor="#374151" thumbTintColor="#2563eb" style={st.slider} />
            <Text style={st.hint}>Minimum dB level to detect speech. Higher = less sensitive.</Text>

            {/* Silence Timeout */}
            <View style={st.sliderLabel}>
              <Text style={st.label}>Silence Timeout</Text>
              <Text style={st.label}>{platformForm.stt_silence_timeout_ms || "500"} ms</Text>
            </View>
            <Slider minimumValue={200} maximumValue={2000} step={50}
              value={parseInt(platformForm.stt_silence_timeout_ms || "500")}
              onValueChange={(v) => setPlatformForm((f) => ({ ...f, stt_silence_timeout_ms: String(v) }))}
              minimumTrackTintColor="#2563eb" maximumTrackTintColor="#374151" thumbTintColor="#2563eb" style={st.slider} />
            <Text style={st.hint}>How long silence must last before ending a recording.</Text>

            {/* Min Duration */}
            <View style={st.sliderLabel}>
              <Text style={st.label}>Min Duration</Text>
              <Text style={st.label}>{platformForm.stt_min_duration_ms || "400"} ms</Text>
            </View>
            <Slider minimumValue={200} maximumValue={1000} step={50}
              value={parseInt(platformForm.stt_min_duration_ms || "400")}
              onValueChange={(v) => setPlatformForm((f) => ({ ...f, stt_min_duration_ms: String(v) }))}
              minimumTrackTintColor="#2563eb" maximumTrackTintColor="#374151" thumbTintColor="#2563eb" style={st.slider} />
            <Text style={st.hint}>Recordings shorter than this are discarded.</Text>

            {/* No-Speech Filter (OpenAI / Whisper only) */}
            {(platformForm.stt_provider ?? "openai") === "openai" && (
            <>
            <View style={st.sliderLabel}>
              <Text style={st.label}>No-Speech Filter</Text>
              <Text style={st.label}>{parseFloat(platformForm.stt_no_speech_threshold || "0.5").toFixed(2)}</Text>
            </View>
            <Slider minimumValue={0.1} maximumValue={0.9} step={0.05}
              value={parseFloat(platformForm.stt_no_speech_threshold || "0.5")}
              onValueChange={(v) => setPlatformForm((f) => ({ ...f, stt_no_speech_threshold: String(v) }))}
              minimumTrackTintColor="#2563eb" maximumTrackTintColor="#374151" thumbTintColor="#2563eb" style={st.slider} />
            <Text style={st.hint}>Whisper segments with no-speech probability above this are filtered. Lower = stricter.</Text>
            </>
            )}

            <TouchableOpacity style={[st.saveBtn, savingPlatform && st.btnDisabled, { marginTop: 20 }]}
              onPress={handleSavePlatform} disabled={savingPlatform}>
              <Text style={st.saveBtnText}>{savingPlatform ? "Saving…" : "Save Settings"}</Text>
            </TouchableOpacity>

            <View style={{ height: 40 }} />
          </ScrollView>
        )}
      </View>
    </Modal>
  );
}

const st = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#111827" },
  header: {
    flexDirection: "row", alignItems: "center", justifyContent: "space-between",
    paddingHorizontal: 16, paddingTop: 56, paddingBottom: 12,
    borderBottomWidth: 1, borderBottomColor: "#1f2937",
  },
  headerTitle: { fontSize: 18, fontWeight: "700", color: "#f9fafb" },
  tabBar: {
    flexDirection: "row", gap: 4, paddingHorizontal: 12, paddingVertical: 8,
    borderBottomWidth: 1, borderBottomColor: "#1f2937",
  },
  tabBtn: { paddingHorizontal: 14, paddingVertical: 6, borderRadius: 8 },
  tabBtnActive: { backgroundColor: "#374151" },
  tabBtnText: { fontSize: 13, fontWeight: "500", color: "#6b7280" },
  tabBtnTextActive: { color: "#f9fafb" },
  agentPicker: { borderBottomWidth: 1, borderBottomColor: "#1f2937", paddingVertical: 10 },
  agentPickerContent: { paddingHorizontal: 12, gap: 8 },
  pill: { flexDirection: "row", alignItems: "center", gap: 6, paddingHorizontal: 12, paddingVertical: 6, borderRadius: 16, backgroundColor: "#1f2937" },
  pillActive: { backgroundColor: "#374151" },
  pillNew: { backgroundColor: "#1e3a5f" },
  pillText: { fontSize: 13, color: "#9ca3af" },
  pillTextActive: { color: "#f9fafb" },
  dot: { width: 8, height: 8, borderRadius: 4 },
  dotHealthy: { backgroundColor: "#34d399" },
  dotError: { backgroundColor: "#f87171" },
  dotUnknown: { backgroundColor: "#6b7280" },
  body: { flex: 1 },
  bodyContent: { padding: 16 },
  healthRow: { flexDirection: "row", alignItems: "center", gap: 8, marginBottom: 12 },
  healthText: { fontSize: 12, color: "#9ca3af" },
  sectionTitle: { fontSize: 11, fontWeight: "600", color: "#6b7280", letterSpacing: 1, marginTop: 20, marginBottom: 8 },
  label: { fontSize: 12, color: "#6b7280", marginBottom: 4, marginTop: 8 },
  hint: { fontSize: 11, color: "#4b5563", marginTop: 2, marginBottom: 8 },
  input: { backgroundColor: "#1f2937", borderRadius: 10, paddingHorizontal: 12, paddingVertical: 10, fontSize: 14, color: "#e5e7eb" },
  inputDisabled: { opacity: 0.5 },
  textArea: { minHeight: 80, paddingTop: 10 },
  picker: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", backgroundColor: "#1f2937", borderRadius: 10, paddingHorizontal: 12, paddingVertical: 12 },
  pickerText: { fontSize: 14, color: "#e5e7eb", flex: 1 },
  sliderLabel: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  slider: { marginTop: 4 },
  actions: { flexDirection: "row", gap: 12, marginTop: 20 },
  saveBtn: { backgroundColor: "#2563eb", borderRadius: 10, paddingHorizontal: 20, paddingVertical: 12 },
  saveBtnText: { color: "#fff", fontSize: 14, fontWeight: "600" },
  deleteBtn: { backgroundColor: "#374151", borderRadius: 10, paddingHorizontal: 20, paddingVertical: 12 },
  deleteBtnText: { color: "#f87171", fontSize: 14, fontWeight: "600" },
  btnDisabled: { opacity: 0.5 },
  separator: { height: 1, backgroundColor: "#1f2937", marginTop: 24, marginBottom: 8 },
});
