import Foundation

struct Agent: Codable, Identifiable, Equatable {
    let agentId: String
    var name: String
    var personaPrompt: String
    var ttsProvider: String
    var voiceId: String
    var voiceSettings: [String: AnyCodableValue]
    var llmProvider: String
    var llmModel: String
    var llmBaseUrl: String?
    var llmApiKey: String?
    var ttsApiKey: String?
    var isOperator: Bool
    var sortOrder: Int
    var status: AgentStatus
    var statusMessage: String

    var id: String { agentId }

    enum AgentStatus: String, Codable {
        case healthy, error, unknown
    }

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case name
        case personaPrompt = "persona_prompt"
        case ttsProvider = "tts_provider"
        case voiceId = "voice_id"
        case voiceSettings = "voice_settings"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
        case llmBaseUrl = "llm_base_url"
        case llmApiKey = "llm_api_key"
        case ttsApiKey = "tts_api_key"
        case isOperator = "is_operator"
        case sortOrder = "sort_order"
        case status
        case statusMessage = "status_message"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        name = try container.decode(String.self, forKey: .name)
        personaPrompt = try container.decode(String.self, forKey: .personaPrompt)
        ttsProvider = try container.decode(String.self, forKey: .ttsProvider)
        voiceId = try container.decode(String.self, forKey: .voiceId)
        voiceSettings = try container.decode([String: AnyCodableValue].self, forKey: .voiceSettings)
        llmProvider = try container.decode(String.self, forKey: .llmProvider)
        llmModel = try container.decode(String.self, forKey: .llmModel)
        llmBaseUrl = try container.decodeIfPresent(String.self, forKey: .llmBaseUrl)
        llmApiKey = try container.decodeIfPresent(String.self, forKey: .llmApiKey)
        ttsApiKey = try container.decodeIfPresent(String.self, forKey: .ttsApiKey)
        isOperator = try container.decode(Bool.self, forKey: .isOperator)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        status = try container.decode(AgentStatus.self, forKey: .status)
        statusMessage = try container.decode(String.self, forKey: .statusMessage)
    }
}
