import Foundation

struct ProviderField {
    let key: String
    let label: String
    let fieldType: FieldType
    let placeholder: String
    let required: Bool
    let options: [(value: String, label: String)]

    enum FieldType {
        case text
        case password
        case select
    }

    init(key: String, label: String, type: FieldType = .text, placeholder: String = "", required: Bool = false, options: [(value: String, label: String)] = []) {
        self.key = key
        self.label = label
        self.fieldType = type
        self.placeholder = placeholder
        self.required = required
        self.options = options
    }
}

struct ProviderSchema {
    let label: String
    let fields: [ProviderField]
}

enum ProviderSchemas {
    // MARK: - LLM Providers

    static let llmProviders: [(key: String, schema: ProviderSchema)] = [
        ("openai", ProviderSchema(label: "OpenAI", fields: [
            ProviderField(key: "llm_api_key", label: "API Key", type: .password, placeholder: "sk-..."),
            ProviderField(key: "llm_model", label: "Model", type: .text, placeholder: "gpt-4o-mini", required: true),
        ])),
        ("anthropic", ProviderSchema(label: "Anthropic", fields: [
            ProviderField(key: "llm_api_key", label: "API Key", type: .password, placeholder: "sk-ant-..."),
            ProviderField(key: "llm_model", label: "Model", type: .text, placeholder: "claude-sonnet-4-5-20250929", required: true),
        ])),
        ("gemini", ProviderSchema(label: "Gemini", fields: [
            ProviderField(key: "llm_api_key", label: "API Key", type: .password, placeholder: "AI..."),
            ProviderField(key: "llm_model", label: "Model", type: .text, placeholder: "gemini-2.0-flash", required: true),
        ])),
        ("ollama", ProviderSchema(label: "Ollama", fields: [
            ProviderField(key: "llm_base_url", label: "Base URL", type: .text, placeholder: "http://localhost:11434/v1"),
            ProviderField(key: "llm_model", label: "Model", type: .text, placeholder: "llama3", required: true),
        ])),
        ("openclaw", ProviderSchema(label: "OpenClaw", fields: [
            ProviderField(key: "llm_base_url", label: "Gateway URL", type: .text, placeholder: "http://localhost:18789", required: true),
            ProviderField(key: "llm_model", label: "Agent ID", type: .text, placeholder: "main", required: true),
            ProviderField(key: "llm_api_key", label: "Auth Token", type: .password, placeholder: "(optional)"),
        ])),
        ("openai-compatible", ProviderSchema(label: "OpenAI-Compatible", fields: [
            ProviderField(key: "llm_base_url", label: "Base URL", type: .text, placeholder: "https://api.example.com/v1", required: true),
            ProviderField(key: "llm_api_key", label: "API Key", type: .password, placeholder: "(optional)"),
            ProviderField(key: "llm_model", label: "Model", type: .text, placeholder: "model-name", required: true),
        ])),
    ]

    // MARK: - TTS Providers

    static let ttsProviders: [(key: String, schema: ProviderSchema)] = [
        ("none", ProviderSchema(label: "None (No TTS)", fields: [])),
        ("openai", ProviderSchema(label: "OpenAI", fields: [
            ProviderField(key: "tts_api_key", label: "API Key", type: .password, placeholder: "sk-... (uses platform key if blank)"),
        ])),
        ("elevenlabs", ProviderSchema(label: "ElevenLabs", fields: [
            ProviderField(key: "tts_api_key", label: "API Key", type: .password, placeholder: "xi-... (uses platform key if blank)"),
        ])),
    ]

    // MARK: - STT Providers

    static let sttProviders: [(key: String, schema: ProviderSchema)] = [
        ("apple", ProviderSchema(label: "Apple (On-Device)", fields: [])),
        ("openai", ProviderSchema(label: "OpenAI (Whisper)", fields: [])),
        ("elevenlabs", ProviderSchema(label: "ElevenLabs (Scribe)", fields: [])),
    ]

    static func llmSchema(for key: String) -> ProviderSchema? {
        llmProviders.first { $0.key == key }?.schema
    }

    static func ttsSchema(for key: String) -> ProviderSchema? {
        ttsProviders.first { $0.key == key }?.schema
    }
}
