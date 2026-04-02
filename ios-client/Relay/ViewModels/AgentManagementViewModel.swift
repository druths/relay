import Foundation

struct Voice: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
}

@Observable
@MainActor
final class AgentManagementViewModel {
    enum Tab: String, CaseIterable {
        case agents = "Agents"
        case tts = "Text to Speech"
        case stt = "Speech to Text"
        case account = "Account"
    }

    var selectedTab: Tab = .agents

    // Agent state
    var selectedAgentId: String?
    var isNewAgent = false
    var form: [String: String] = [:]
    var voices: [Voice] = []
    var isSaving = false

    // Platform settings state
    var platform: PlatformSettings?
    var platformForm: [String: String] = [:]
    var isSavingPlatform = false

    // Dirty state tracking
    private var savedForm: [String: String] = [:]
    private var savedPlatformForm: [String: String] = [:]
    var isAgentFormDirty: Bool { form != savedForm }
    var isPlatformFormDirty: Bool { platformForm != savedPlatformForm }

    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Loading

    func loadPlatformSettings() async {
        do {
            let settings: PlatformSettings = try await apiClient.request("GET", path: "/v1/platform/settings")
            platform = settings

            // Use local provider override if set, otherwise use server provider
            let localProvider = UserDefaults.standard.string(forKey: "stt_local_provider")
            let sttProvider = localProvider ?? settings.sttProvider

            platformForm = [
                "stt_provider": sttProvider,
                "stt_api_key": settings.sttApiKey ?? "",
                "stt_silence_threshold_db": String(settings.sttSilenceThresholdDb),
                "stt_silence_timeout_ms": String(settings.sttSilenceTimeoutMs),
                "stt_min_duration_ms": String(settings.sttMinDurationMs),
                "stt_no_speech_threshold": String(settings.sttNoSpeechThreshold),
                "stt_attack_debounce_ms": String(settings.sttAttackDebounceMs),
                "tts_default_provider": settings.ttsDefaultProvider,
                "tts_openai_api_key": "",
                "tts_elevenlabs_api_key": "",
                "voice_mode_instructions": settings.voiceModeInstructions,
            ]
            savedPlatformForm = platformForm
        } catch {
            print("[AgentMgmt] Failed to load platform settings: \(error)")
        }
    }

    func selectAgent(_ agent: Agent) {
        isNewAgent = false
        selectedAgentId = agent.agentId
        form = [
            "name": agent.name,
            "persona_prompt": agent.personaPrompt,
            "llm_provider": agent.llmProvider,
            "llm_model": agent.llmModel,
            "llm_base_url": agent.llmBaseUrl ?? "",
            "llm_api_key": agent.llmApiKey ?? "",
            "tts_provider": agent.ttsProvider,
            "tts_api_key": agent.ttsApiKey ?? "",
            "voice_id": agent.voiceId,
            "speed": agent.voiceSettings["speed"]?.stringValue ?? "1.0",
            "model": agent.voiceSettings["model"]?.stringValue ?? "tts-1",
            "model_id": agent.voiceSettings["model_id"]?.stringValue ?? "eleven_multilingual_v2",
            "stability": agent.voiceSettings["stability"]?.stringValue ?? "0.5",
            "similarity_boost": agent.voiceSettings["similarity_boost"]?.stringValue ?? "0.75",
        ]
        savedForm = form
    }

    func startNewAgent() {
        isNewAgent = true
        selectedAgentId = nil
        form = [
            "name": "",
            "persona_prompt": "",
            "llm_provider": "openai",
            "llm_model": "gpt-4o-mini",
            "llm_base_url": "",
            "llm_api_key": "",
            "tts_provider": "none",
            "tts_api_key": "",
            "voice_id": "",
            "speed": "1",
            "model": "tts-1",
            "model_id": "eleven_multilingual_v2",
            "stability": "0.5",
            "similarity_boost": "0.75",
        ]
        savedForm = form
    }

    // MARK: - Voices

    func fetchVoices() async {
        let provider = form["tts_provider"] ?? "none"
        guard provider != "none" else {
            voices = []
            return
        }

        let apiKey = form["tts_api_key"] ?? ""
        let isRealKey = !apiKey.isEmpty && !apiKey.contains("\u{2022}")

        var params: [String] = []
        if isRealKey, let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            params.append("api_key=\(encoded)")
        }
        if provider == "elevenlabs", let modelId = form["model_id"], !modelId.isEmpty {
            params.append("model_id=\(modelId)")
        }
        let qs = params.isEmpty ? "" : "?\(params.joined(separator: "&"))"

        do {
            let fetched: [Voice] = try await apiClient.request("GET", path: "/v1/agents/tts/voices/\(provider)\(qs)")
            voices = fetched
        } catch {
            voices = []
        }
    }

    // MARK: - Save Agent

    func saveAgent(agents: [Agent]) async throws -> String? {
        isSaving = true
        defer { isSaving = false }

        let voiceSettings = buildVoiceSettings()

        if isNewAgent {
            let body: [String: AnyCodableValue] = [
                "name": .string(form["name"] ?? ""),
                "persona_prompt": .string(form["persona_prompt"] ?? ""),
                "llm_provider": .string(form["llm_provider"] ?? "openai"),
                "llm_model": .string(form["llm_model"] ?? ""),
                "llm_base_url": form["llm_base_url"]?.isEmpty == false ? .string(form["llm_base_url"]!) : .null,
                "llm_api_key": form["llm_api_key"]?.isEmpty == false ? .string(form["llm_api_key"]!) : .null,
                "tts_provider": .string(form["tts_provider"] ?? "none"),
                "tts_api_key": form["tts_api_key"]?.isEmpty == false ? .string(form["tts_api_key"]!) : .null,
                "voice_id": .string(form["voice_id"] ?? ""),
                "voice_settings": .dict(voiceSettings),
            ]
            let created: Agent = try await apiClient.request("POST", path: "/v1/agents", body: AgentUpdateBody(values: body))
            isNewAgent = false
            selectedAgentId = created.agentId
            savedForm = form
            return created.agentId
        } else if let agentId = selectedAgentId {
            let selected = agents.first { $0.agentId == agentId }
            var body: [String: AnyCodableValue] = [
                "persona_prompt": .string(form["persona_prompt"] ?? ""),
                "llm_provider": .string(form["llm_provider"] ?? "openai"),
                "llm_model": .string(form["llm_model"] ?? ""),
                "llm_base_url": .string(form["llm_base_url"] ?? ""),
                "tts_provider": .string(form["tts_provider"] ?? "none"),
                "voice_id": .string(form["voice_id"] ?? ""),
                "voice_settings": .dict(voiceSettings),
            ]

            if let selected, !selected.isOperator, form["name"] != selected.name {
                body["name"] = .string(form["name"] ?? "")
            }
            if form["llm_api_key"] != (selected?.llmApiKey ?? "") {
                body["llm_api_key"] = .string(form["llm_api_key"] ?? "")
            }
            if form["tts_api_key"] != (selected?.ttsApiKey ?? "") {
                body["tts_api_key"] = .string(form["tts_api_key"] ?? "")
            }

            let _: Agent = try await apiClient.request("PATCH", path: "/v1/agents/\(agentId)/config", body: AgentUpdateBody(values: body))
            savedForm = form
            return agentId
        }

        return nil
    }

    // MARK: - Delete Agent

    func deleteAgent(_ agentId: String) async throws {
        try await apiClient.delete(path: "/v1/agents/\(agentId)")
    }

    // MARK: - Reorder Agents

    func reorderAgents(ids: [String]) async {
        struct ReorderBody: Encodable {
            let agent_ids: [String]
        }
        do {
            let _: [Agent] = try await apiClient.request("PUT", path: "/v1/agents/reorder", body: ReorderBody(agent_ids: ids))
        } catch {
            print("[AgentMgmt] Failed to reorder agents: \(error)")
        }
    }

    // MARK: - Save Platform Settings

    func savePlatformSettings() async throws {
        isSavingPlatform = true
        defer { isSavingPlatform = false }

        let selectedProvider = platformForm["stt_provider"] ?? "openai"
        let isLocalStt = selectedProvider == "apple"

        // Persist local STT choice in UserDefaults
        if isLocalStt {
            UserDefaults.standard.set("apple", forKey: "stt_local_provider")
        } else {
            UserDefaults.standard.removeObject(forKey: "stt_local_provider")
        }

        var body: [String: AnyCodableValue] = [:]

        // Don't send "apple" to server — it's iOS-only
        if !isLocalStt, let provider = platformForm["stt_provider"] {
            body["stt_provider"] = .string(provider)
        }
        if !isLocalStt, platformForm["stt_api_key"] != (platform?.sttApiKey ?? "") {
            body["stt_api_key"] = .string(platformForm["stt_api_key"] ?? "")
        }
        body["stt_silence_threshold_db"] = .double(Double(platformForm["stt_silence_threshold_db"] ?? "-35") ?? -35)
        body["stt_silence_timeout_ms"] = .int(Int(Double(platformForm["stt_silence_timeout_ms"] ?? "500") ?? 500))
        body["stt_min_duration_ms"] = .int(Int(Double(platformForm["stt_min_duration_ms"] ?? "400") ?? 400))
        body["stt_no_speech_threshold"] = .double(Double(platformForm["stt_no_speech_threshold"] ?? "0.5") ?? 0.5)
        body["stt_attack_debounce_ms"] = .int(Int(Double(platformForm["stt_attack_debounce_ms"] ?? "300") ?? 300))

        if let provider = platformForm["tts_default_provider"] {
            body["tts_default_provider"] = .string(provider)
        }
        if let key = platformForm["tts_openai_api_key"], !key.isEmpty {
            body["tts_openai_api_key"] = .string(key)
        }
        if let key = platformForm["tts_elevenlabs_api_key"], !key.isEmpty {
            body["tts_elevenlabs_api_key"] = .string(key)
        }
        if let instructions = platformForm["voice_mode_instructions"] {
            body["voice_mode_instructions"] = .string(instructions)
        }

        let updated: PlatformSettings = try await apiClient.request("PATCH", path: "/v1/platform/settings", body: AgentUpdateBody(values: body))
        platform = updated
        platformForm["stt_api_key"] = updated.sttApiKey ?? ""
        platformForm["stt_silence_threshold_db"] = String(updated.sttSilenceThresholdDb)
        platformForm["stt_silence_timeout_ms"] = String(updated.sttSilenceTimeoutMs)
        platformForm["stt_min_duration_ms"] = String(updated.sttMinDurationMs)
        platformForm["stt_no_speech_threshold"] = String(updated.sttNoSpeechThreshold)
        platformForm["stt_attack_debounce_ms"] = String(updated.sttAttackDebounceMs)
        platformForm["tts_default_provider"] = updated.ttsDefaultProvider
        platformForm["tts_openai_api_key"] = ""
        platformForm["tts_elevenlabs_api_key"] = ""
        platformForm["voice_mode_instructions"] = updated.voiceModeInstructions
        savedPlatformForm = platformForm
    }

    // MARK: - Helpers

    private func buildVoiceSettings() -> [String: AnyCodableValue] {
        let provider = form["tts_provider"] ?? "none"
        switch provider {
        case "openai":
            return [
                "speed": .double(Double(form["speed"] ?? "1") ?? 1.0),
                "model": .string(form["model"] ?? "tts-1"),
            ]
        case "elevenlabs":
            return [
                "stability": .double(Double(form["stability"] ?? "0.5") ?? 0.5),
                "similarity_boost": .double(Double(form["similarity_boost"] ?? "0.75") ?? 0.75),
                "model_id": .string(form["model_id"] ?? "eleven_multilingual_v2"),
            ]
        default:
            return [:]
        }
    }
}
