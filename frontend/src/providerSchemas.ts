/**
 * Provider schema registry — declares what form fields each provider needs.
 * Adding a new provider = adding one entry here.
 */

export interface ProviderField {
  key: string;
  label: string;
  type: "text" | "password" | "select";
  placeholder?: string;
  required?: boolean;
  options?: { value: string; label: string }[];
}

export interface ProviderSchema {
  label: string;
  fields: ProviderField[];
}

export const LLM_PROVIDERS: Record<string, ProviderSchema> = {
  openai: {
    label: "OpenAI",
    fields: [
      { key: "llm_api_key", label: "API Key", type: "password", placeholder: "sk-…" },
      { key: "llm_model", label: "Model", type: "text", placeholder: "gpt-4o-mini", required: true },
    ],
  },
  anthropic: {
    label: "Anthropic",
    fields: [
      { key: "llm_api_key", label: "API Key", type: "password", placeholder: "sk-ant-…" },
      { key: "llm_model", label: "Model", type: "text", placeholder: "claude-sonnet-4-5-20250929", required: true },
    ],
  },
  gemini: {
    label: "Gemini",
    fields: [
      { key: "llm_api_key", label: "API Key", type: "password", placeholder: "AI…" },
      { key: "llm_model", label: "Model", type: "text", placeholder: "gemini-2.0-flash", required: true },
    ],
  },
  ollama: {
    label: "Ollama",
    fields: [
      { key: "llm_base_url", label: "Base URL", type: "text", placeholder: "http://localhost:11434/v1" },
      { key: "llm_model", label: "Model", type: "text", placeholder: "llama3", required: true },
    ],
  },
  openclaw: {
    label: "OpenClaw",
    fields: [
      { key: "llm_base_url", label: "Gateway URL", type: "text", placeholder: "http://localhost:18789", required: true },
      { key: "llm_model", label: "Agent ID", type: "text", placeholder: "main", required: true },
      { key: "llm_api_key", label: "Auth Token", type: "password", placeholder: "(optional)" },
    ],
  },
  "openai-compatible": {
    label: "OpenAI-Compatible",
    fields: [
      { key: "llm_base_url", label: "Base URL", type: "text", placeholder: "https://api.example.com/v1", required: true },
      { key: "llm_api_key", label: "API Key", type: "password", placeholder: "(optional)" },
      { key: "llm_model", label: "Model", type: "text", placeholder: "model-name", required: true },
    ],
  },
  ark: {
    label: "Ark",
    fields: [
      { key: "llm_base_url", label: "Server URL", type: "text", placeholder: "http://localhost:7777", required: true },
      { key: "llm_model", label: "Agent Name", type: "text", placeholder: "assistant", required: true },
      { key: "llm_api_key", label: "Auth Token", type: "password", placeholder: "(shared bearer secret)" },
    ],
  },
};

export const TTS_PROVIDERS: Record<string, ProviderSchema> = {
  none: {
    label: "None (No TTS)",
    fields: [],
  },
  openai: {
    label: "OpenAI-Compatible",
    fields: [
      { key: "tts_api_key", label: "API Key", type: "password", placeholder: "sk-… (blank for local TTS)" },
      { key: "base_url", label: "Base URL", type: "text", placeholder: "Blank for OpenAI, or http://kokoro:8880 for local" },
    ],
  },
  elevenlabs: {
    label: "ElevenLabs",
    fields: [
      { key: "tts_api_key", label: "API Key", type: "password", placeholder: "xi-… (uses platform key if blank)" },
    ],
  },
  neutts: {
    label: "NeuTTS (self-hosted)",
    fields: [
      { key: "base_url", label: "Server URL", type: "text", placeholder: "Blank to use default neutts:8000" },
    ],
  },
};

export const LLM_PROVIDER_OPTIONS = Object.entries(LLM_PROVIDERS).map(([value, schema]) => ({
  value,
  label: schema.label,
}));

export const TTS_PROVIDER_OPTIONS = Object.entries(TTS_PROVIDERS).map(([value, schema]) => ({
  value,
  label: schema.label,
}));

export const STT_PROVIDERS: Record<string, ProviderSchema> = {
  openai: {
    label: "OpenAI (Whisper)",
    fields: [],
  },
  elevenlabs: {
    label: "ElevenLabs (Scribe)",
    fields: [],
  },
};

export const STT_PROVIDER_OPTIONS = Object.entries(STT_PROVIDERS).map(([value, schema]) => ({
  value,
  label: schema.label,
}));
