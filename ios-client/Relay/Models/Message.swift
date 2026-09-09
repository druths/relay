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
    /// Optional workspace/project reference. When present, the pill
    /// becomes tap-to-open-in-editor for openable extensions and falls
    /// back to download-on-tap for binaries. Absent on legacy /
    /// user-upload attachments — those stay download-only.
    var kind: String? = nil    // "workspace" | "project"
    /// For `kind == "workspace"`, the ark agent name owning the
    /// workspace. For `kind == "project"`, the ark project id.
    var scope: String? = nil
    /// Path relative to the workspace or project root.
    var path: String? = nil

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case url
        case kind
        case scope
        case path
    }
}

struct TokenUsage: Equatable, Codable {
    var inputTokens: Int?
    var outputTokens: Int?
    var contextWindow: Int?
    var model: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case contextWindow = "context_window"
        case model
    }
}

struct MessageMetadata: Equatable, Codable {
    var usage: TokenUsage?
    /// Set on `role: .compaction` marker rows. Values mirror ark's:
    /// `auto:proactive`, `auto:reactive`, `client-invoked`,
    /// `client-supplied`, or a `disabled:*` variant.
    var reason: String?
    /// Set on `role: .projectChange` marker rows. Both endpoints may be
    /// nil (first-time-assign / detach). Names are the human labels ark
    /// resolved at change-time — they stay correct even if the project
    /// is later renamed.
    var fromProjectId: String?
    var toProjectId: String?
    var fromProjectName: String?
    var toProjectName: String?
    /// Set on `role: .error` marker rows. `code` is ark's classified
    /// RunError kind (context_too_long / rate_limit / auth /
    /// token_budget_exceeded / other); `message` is the raw provider
    /// text so the divider can expose it to the user.
    var code: String?
    var message: String?
    /// Source agent name on cross-session-injected agent messages.
    /// Absent on normal turns from the session's own agent. Clients
    /// compare against the previous message's speaker to decide
    /// whether to draw a "different agent" header boundary.
    var speaker: String?

    enum CodingKeys: String, CodingKey {
        case usage
        case reason
        case fromProjectId = "from_project_id"
        case toProjectId = "to_project_id"
        case fromProjectName = "from_project_name"
        case toProjectName = "to_project_name"
        case code
        case message
        case speaker
    }
}

struct Message: Identifiable, Equatable {
    let id: UUID
    var role: MessageRole
    var textContent: String
    var createdAt: Date?
    var isStreaming: Bool
    var isInterrupted: Bool
    var attachments: [FileAttachment]
    var metadata: MessageMetadata?

    enum MessageRole: String {
        case user
        case `operator`
        case agent
        case system  // client-side markers (e.g., "Session ended")
        case compaction  // ark session summary — rendered as a divider
        case projectChange = "project_change"  // ark project (re)assign — divider
        case error  // ark RunError — rendered as a red divider
    }

    init(
        role: MessageRole,
        textContent: String,
        createdAt: Date? = nil,
        isStreaming: Bool = false,
        isInterrupted: Bool = false,
        attachments: [FileAttachment] = [],
        metadata: MessageMetadata? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.textContent = textContent
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.isInterrupted = isInterrupted
        self.attachments = attachments
        self.metadata = metadata
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
    /// Optional workspace/project reference — server sets these on
    /// agent-shared files (File rows whose storage_path is
    /// `ark:<agent>:<path>`). Absent on user uploads and legacy rows.
    let kind: String?
    let scope: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case url
        case kind
        case scope
        case path
    }
}

struct ServerMessage: Codable {
    let messageId: String?
    let role: String
    let textContent: String
    let createdAt: String?
    let attachments: [ServerAttachment]?
    let metadata: MessageMetadata?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case role
        case textContent = "text_content"
        case createdAt = "created_at"
        case attachments
        case metadata
    }

    // Date formatters are thread-safe for reading on iOS 7+; the
    // `nonisolated(unsafe)` opt-out is the standard escape from Swift 6's
    // strict-concurrency static-property check.
    nonisolated(unsafe) private static let _iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let _isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func toMessage() -> Message {
        let messageRole: Message.MessageRole
        switch role {
        case "user": messageRole = .user
        case "agent": messageRole = .agent
        case "compaction": messageRole = .compaction
        case "project_change": messageRole = .projectChange
        case "error": messageRole = .error
        default: messageRole = .operator
        }
        let mapped = (attachments ?? []).map {
            FileAttachment(
                fileId: $0.fileId,
                filename: $0.filename,
                mimeType: $0.mimeType,
                sizeBytes: $0.sizeBytes,
                url: $0.url,
                kind: $0.kind,
                scope: $0.scope,
                path: $0.path,
            )
        }
        let parsedDate: Date? = {
            guard let s = createdAt else { return nil }
            return Self._iso.date(from: s) ?? Self._isoNoFrac.date(from: s)
        }()
        return Message(
            role: messageRole,
            textContent: textContent,
            createdAt: parsedDate,
            attachments: mapped,
            metadata: metadata,
        )
    }
}
