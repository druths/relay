import Foundation

struct FileAttachment: Identifiable, Equatable, Codable {
    var id: String { fileId ?? "\(filename)-\(sizeBytes)" }
    var fileId: String?
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    /// Either a Relay-internal URL (`/v1/files/<id>/<name>`) or an
    /// ark-passthrough URL (`/v1/files/ark/<agent>/<workspace-path>`).
    var url: String
}

struct Message: Identifiable, Equatable {
    let id: UUID
    var role: MessageRole
    var textContent: String
    var createdAt: Date?
    var isStreaming: Bool
    var isInterrupted: Bool
    var attachments: [FileAttachment]

    enum MessageRole: String {
        case user
        case `operator`
        case agent
        case system  // client-side markers (e.g., "Session ended")
    }

    init(
        role: MessageRole,
        textContent: String,
        createdAt: Date? = nil,
        isStreaming: Bool = false,
        isInterrupted: Bool = false,
        attachments: [FileAttachment] = []
    ) {
        self.id = UUID()
        self.role = role
        self.textContent = textContent
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.isInterrupted = isInterrupted
        self.attachments = attachments
    }
}

// For decoding session history messages from the server.
// Attachments may appear on either a real text message or a synthetic
// upload/agent-share entry whose text_content is empty.
struct ServerAttachment: Codable {
    let fileId: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let url: String

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case url
    }
}

struct ServerMessage: Codable {
    let messageId: String?
    let role: String
    let textContent: String
    let createdAt: String?
    let attachments: [ServerAttachment]?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case role
        case textContent = "text_content"
        case createdAt = "created_at"
        case attachments
    }

    func toMessage() -> Message {
        let messageRole: Message.MessageRole
        switch role {
        case "user": messageRole = .user
        case "agent": messageRole = .agent
        default: messageRole = .operator
        }
        let mapped = (attachments ?? []).map {
            FileAttachment(
                fileId: $0.fileId,
                filename: $0.filename,
                mimeType: $0.mimeType,
                sizeBytes: $0.sizeBytes,
                url: $0.url,
            )
        }
        return Message(role: messageRole, textContent: textContent, attachments: mapped)
    }
}
