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
    }
}
