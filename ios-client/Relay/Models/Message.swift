import Foundation

struct Message: Identifiable, Equatable {
    let id: UUID
    var role: MessageRole
    var textContent: String
    var createdAt: Date?
    var isStreaming: Bool
    var isInterrupted: Bool

    enum MessageRole: String {
        case user
        case `operator`
        case agent
        case system  // client-side markers (e.g., "Session ended")
    }

    init(role: MessageRole, textContent: String, createdAt: Date? = nil, isStreaming: Bool = false, isInterrupted: Bool = false) {
        self.id = UUID()
        self.role = role
        self.textContent = textContent
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.isInterrupted = isInterrupted
    }
}

// For decoding session history messages from the server
struct ServerMessage: Codable {
    let messageId: String?
    let role: String
    let textContent: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case role
        case textContent = "text_content"
        case createdAt = "created_at"
    }

    func toMessage() -> Message {
        let messageRole: Message.MessageRole
        switch role {
        case "user": messageRole = .user
        case "agent": messageRole = .agent
        default: messageRole = .operator
        }
        return Message(role: messageRole, textContent: textContent)
    }
}
