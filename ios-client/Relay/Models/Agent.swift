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
        case status
        case statusMessage = "status_message"
    }
}
