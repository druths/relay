import Foundation

struct Session: Codable, Identifiable, Equatable {
    let sessionId: String
    let agentId: String
    var agentName: String
    var status: String
    var createdAt: String
    var lastActive: String
    var name: String?
    var summary: String?
    var labels: [String]

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentId = "agent_id"
        case agentName = "agent_name"
        case status
        case createdAt = "created_at"
        case lastActive = "last_active"
        case name
        case summary
        case labels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        agentId = try container.decode(String.self, forKey: .agentId)
        agentName = try container.decode(String.self, forKey: .agentName)
        status = try container.decode(String.self, forKey: .status)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastActive = try container.decode(String.self, forKey: .lastActive)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}
