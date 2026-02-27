import { useEffect, useRef, useState } from "react";
import type { Agent } from "../types";
import { apiFetch } from "../api";

interface Voice {
  id: string;
  name: string;
  description: string;
}

interface VoiceSettingsProps {
  agents: Agent[];
  onUpdate: (agentId: string, config: { voice_settings?: Record<string, number>; voice_id?: string }) => void;
}

export function VoiceSettings({ agents, onUpdate }: VoiceSettingsProps) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [voices, setVoices] = useState<Voice[]>([]);
  const voiceCacheRef = useRef<Record<string, Voice[]>>({});

  const selected = agents.find((a) => a.agent_id === selectedId);

  // Fetch available voices when the selected agent's TTS provider changes
  useEffect(() => {
    if (!selected || selected.tts_provider === "none") {
      setVoices([]);
      return;
    }

    const provider = selected.tts_provider;

    // Use cache if available
    if (voiceCacheRef.current[provider]) {
      setVoices(voiceCacheRef.current[provider]);
      return;
    }

    apiFetch(`/v1/agents/tts/voices/${provider}`)
      .then((r) => r.json())
      .then((data: Voice[]) => {
        voiceCacheRef.current[provider] = data;
        setVoices(data);
      })
      .catch(() => setVoices([]));
  }, [selected?.tts_provider]);

  return (
    <div className="space-y-3">
      <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider px-1">
        Voice Settings
      </h3>

      <select
        value={selectedId || ""}
        onChange={(e) => setSelectedId(e.target.value || null)}
        className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
      >
        <option value="">Select agent…</option>
        {agents.map((a) => (
          <option key={a.agent_id} value={a.agent_id}>
            {a.name}
          </option>
        ))}
      </select>

      {selected && selected.tts_provider === "none" && (
        <p className="text-xs text-gray-600">No TTS configured.</p>
      )}

      {selected && selected.tts_provider !== "none" && (
        <div className="space-y-2">
          {/* Voice selector */}
          {voices.length > 0 && (
            <div>
              <label className="text-xs text-gray-400 mb-1 block">Voice</label>
              <select
                value={selected.voice_id}
                onChange={(e) => {
                  onUpdate(selected.agent_id, { voice_id: e.target.value });
                }}
                className="w-full bg-gray-800 rounded-lg px-3 py-2 text-sm outline-none"
              >
                {voices.map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.name} — {v.description}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Voice settings sliders */}
          {Object.entries(selected.voice_settings).map(([key, val]) => {
            // OpenAI TTS speed range is 0.25-4.0
            const isSpeed = key === "speed";
            const min = isSpeed ? 0.25 : 0;
            const max = isSpeed ? 4.0 : 1;
            const step = isSpeed ? 0.25 : 0.05;
            return (
              <div key={key}>
                <label className="flex justify-between text-xs text-gray-400 mb-1">
                  <span>{key}</span>
                  <span>{(val as number).toFixed(2)}</span>
                </label>
                <input
                  type="range"
                  min={min}
                  max={max}
                  step={step}
                  value={val as number}
                  onChange={(e) => {
                    const newSettings = {
                      ...selected.voice_settings,
                      [key]: parseFloat(e.target.value),
                    };
                    onUpdate(selected.agent_id, { voice_settings: newSettings });
                  }}
                  className="w-full accent-blue-500"
                />
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
