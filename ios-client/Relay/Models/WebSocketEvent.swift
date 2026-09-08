import Foundation

// MARK: - Server → Client events

enum WebSocketEvent {
    case stateUpdate(StateUpdatePayload)
    case text(TextPayload)
    case handoff(HandoffPayload)
    case sessionEntered(SessionEnteredPayload)
    case sessionLeft(SessionLeftPayload)
    case sessionHistory(SessionHistoryPayload)
    case sessionNamed(SessionNamedPayload)
    case sessionRenamed(SessionRenamedPayload)
    case sessionLabelsUpdated(SessionLabelsUpdatedPayload)
    case sessionDeleted(SessionDeletedPayload)
    case sessionUnread(SessionUnreadPayload)
    case sessionStatus(SessionStatusPayload)
    case textStart(TextStartPayload)
    case textDelta(TextDeltaPayload)
    case textDone(TextDonePayload)
    case audioStart(AudioStartPayload)
    case audioChunk(AudioChunkPayload)
    case audioDone(AudioDonePayload)
    case transcription(TranscriptionPayload)
    case agentFile(AgentFilePayload)
    case projectFileChanged(ProjectFileChangedPayload)
    case workspaceFileChanged(WorkspaceFileChangedPayload)
    case compactionStarted(CompactionStartedPayload)
    case compactionCompleted(CompactionCompletedPayload)
    case compactionFailed(CompactionFailedPayload)
    case compactionSkipped(CompactionSkippedPayload)
    case agentActivity(AgentActivityPayload)
    case sessionProjectChanged(SessionProjectChangedPayload)
    case sessionError(SessionErrorPayload)
    case error(ErrorPayload)
}

struct StateUpdatePayload: Codable {
    let activeSpeaker: String
    let status: String
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case activeSpeaker = "active_speaker"
        case status
        case sessionId = "session_id"
    }
}

struct TextPayload: Codable {
    let speaker: String
    let text: String
    /// Set when the event targets a specific session (e.g. ark
    /// injected_message). If absent, the event applies to the user's
    /// current conversation context.
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case speaker, text
        case sessionId = "session_id"
    }
}

struct HandoffPayload: Codable {
    let from: String
    let to: String
    let playEarcon: Bool

    enum CodingKeys: String, CodingKey {
        case from, to
        case playEarcon = "play_earcon"
    }
}

struct SessionEnteredPayload: Codable {
    let sessionId: String
    let agentName: String
    let labels: [String]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case labels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        agentName = try container.decode(String.self, forKey: .agentName)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

struct SessionHistoryPayload: Codable {
    let messages: [ServerMessage]
}

struct SessionNamedPayload: Codable {
    let sessionId: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case name
    }
}

struct SessionRenamedPayload: Codable {
    let sessionId: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case name
    }
}

struct SessionLabelsUpdatedPayload: Codable {
    let sessionId: String
    let labels: [String]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case labels
    }
}

struct SessionDeletedPayload: Codable {
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

/// Payload for `session_left`. `sessionId` is the session that was left
/// (or `nil` when the server cleared us from a session that no longer
/// exists). `reason` is a stable token the client can switch on; `detail`
/// carries unstructured context (e.g. the matched text that tripped the
/// regex intent matcher) for the activity log.
struct SessionLeftPayload: Codable, Sendable {
    let sessionId: String?
    let reason: String?
    let detail: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case reason
        case detail
    }
}


struct SessionUnreadPayload: Codable {
    let sessionId: String
    let hasUnread: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hasUnread = "has_unread"
    }
}

struct SessionStatusPayload: Codable {
    let sessionId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status
    }
}

struct TextStartPayload: Codable {
    let speaker: String
}

struct TextDeltaPayload: Codable {
    let speaker: String
    let delta: String
}

struct TextDonePayload: Codable {
    let speaker: String
    let text: String
    let metadata: MessageMetadata?
    /// Set when the turn ended via the Stop button (ark cancelled
    /// mid-turn and emitted `done {stopped: true}`). The VM applies
    /// this to the streaming bubble so it renders the interrupted
    /// affordance. Absent on natural completions.
    let interrupted: Bool?
    /// Ark's stop_reason (e.g. `"stopped"`), present alongside
    /// `interrupted`. Kept for future diagnostics.
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case speaker
        case text
        case metadata
        case interrupted
        case stopReason = "stop_reason"
    }
}

struct AudioStartPayload: Codable {
    let speaker: String
}

struct AudioChunkPayload: Codable {
    let speaker: String
    let data: String
    let format: String
    let sequence: Int
}

struct AudioDonePayload: Codable {
    let speaker: String
}

struct TranscriptionPayload: Codable {
    let text: String
}

struct ErrorPayload: Codable {
    let message: String
}

struct AgentFilePayload: Codable {
    let sessionId: String
    let agentName: String
    let path: String
    let description: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case path
        case description
        case size
    }
}

/// Relay forwards ark's `project_file_changed` events nested under
/// `payload`. ark itself emits them flat — accept either shape so we cope
/// with both wire formats without tweaking the backend.
struct ProjectFileChangedPayload: Codable {
    let projectId: String
    let path: String
    let change: String

    enum OuterKeys: String, CodingKey {
        case payload, projectId = "project_id", path, change
    }
    enum InnerKeys: String, CodingKey {
        case projectId = "project_id", path, change
    }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKeys.self)
        if let nested = try? outer.nestedContainer(keyedBy: InnerKeys.self, forKey: .payload) {
            projectId = try nested.decode(String.self, forKey: .projectId)
            path = try nested.decode(String.self, forKey: .path)
            change = try nested.decode(String.self, forKey: .change)
        } else {
            projectId = try outer.decode(String.self, forKey: .projectId)
            path = try outer.decode(String.self, forKey: .path)
            change = try outer.decode(String.self, forKey: .change)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: InnerKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(path, forKey: .path)
        try c.encode(change, forKey: .change)
    }
}

struct WorkspaceFileChangedPayload: Codable {
    let agentName: String
    let path: String
    let change: String

    enum OuterKeys: String, CodingKey {
        case payload, agentName = "agent_name", path, change
    }
    enum InnerKeys: String, CodingKey {
        case agentName = "agent_name", path, change
    }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKeys.self)
        if let nested = try? outer.nestedContainer(keyedBy: InnerKeys.self, forKey: .payload) {
            agentName = try nested.decode(String.self, forKey: .agentName)
            path = try nested.decode(String.self, forKey: .path)
            change = try nested.decode(String.self, forKey: .change)
        } else {
            agentName = try outer.decode(String.self, forKey: .agentName)
            path = try outer.decode(String.self, forKey: .path)
            change = try outer.decode(String.self, forKey: .change)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: InnerKeys.self)
        try c.encode(agentName, forKey: .agentName)
        try c.encode(path, forKey: .path)
        try c.encode(change, forKey: .change)
    }
}

// MARK: - Compaction events

/// Fires when ark starts compacting a session (automatic threshold cross,
/// reactive `context_too_long`, or a client-invoked POST). Between this
/// and the matching completed / failed / skipped event, clients should
/// show a "compacting…" indicator and refuse to send new messages.
struct CompactionStartedPayload: Codable {
    let sessionId: String
    let agentName: String
    let reason: String
    let inputTokens: Int?
    let contextWindow: Int?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case reason
        case inputTokens = "input_tokens"
        case contextWindow = "context_window"
        case model
    }
}

struct CompactionCompletedPayload: Codable {
    let sessionId: String
    let agentName: String
    let reason: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case reason, summary
    }
}

struct CompactionFailedPayload: Codable {
    let sessionId: String
    let agentName: String
    let reason: String
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case reason, code, message
    }
}

struct CompactionSkippedPayload: Codable {
    let sessionId: String
    let agentName: String
    let reason: String
    let inputTokens: Int?
    let contextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case reason
        case inputTokens = "input_tokens"
        case contextWindow = "context_window"
    }
}

/// Fires when a session's turn terminates with a `RunError` (ark's four
/// classified codes: context_too_long, rate_limit, auth,
/// token_budget_exceeded, plus a catch-all `other`). Clients sweep any
/// in-flight streaming bubble to interrupted and drop a red-tinted
/// divider into the transcript with the code + message.
struct SessionErrorPayload: Codable {
    let sessionId: String
    let agentName: String
    let code: String
    let message: String
    /// Server-composed "code: message" label so all clients render the
    /// same divider text.
    let markerText: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case code
        case message
        case markerText = "marker_text"
    }
}

/// Fired when a session's ark project binding changes (assign / reassign
/// / detach). Only real changes emit — no-op PATCHes are silent. Clients
/// update the session's `projectId` in place and drop a divider into the
/// transcript at the marker's arrival point.
struct SessionProjectChangedPayload: Codable {
    let sessionId: String
    let agentName: String
    let fromProjectId: String?
    let fromProjectName: String?
    let toProjectId: String?
    let toProjectName: String?
    /// Server-composed label so all clients render the same divider text.
    let markerText: String
    let changedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
        case fromProjectId = "from_project_id"
        case fromProjectName = "from_project_name"
        case toProjectId = "to_project_id"
        case toProjectName = "to_project_name"
        case markerText = "marker_text"
        case changedAt = "changed_at"
    }
}

/// Streamed mid-turn from ark: `thinking` deltas, `tool_call`
/// invocations, and `tool_result` outputs. The `detail` blob is ark's
/// raw event body — clients read it as opaque JSON so we don't need
/// to keep this in lockstep with ark's schema as it evolves.
struct AgentActivityPayload: Codable {
    let sessionId: String
    let speaker: String
    let kind: String        // "thinking" | "tool_call" | "tool_result"
    let detail: JSONValue

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case speaker, kind, detail
    }
}

// MARK: - Decoding

extension WebSocketEvent {
    /// Decode a JSON string from the WebSocket into a typed event.
    static func decode(from jsonString: String) -> WebSocketEvent? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return decode(from: data)
    }

    static func decode(from data: Data) -> WebSocketEvent? {
        struct Envelope: Codable {
            let type: String
            let payload: AnyCodablePayload?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            print("[WS] Failed to decode envelope")
            return nil
        }

        // Re-encode the payload portion for type-specific decoding
        guard let payloadData = envelope.payload?.data else {
            // Older servers send `session_left` with no payload — keep
            // accepting it, but emit an empty SessionLeftPayload so the
            // type system is consistent with the payload-bearing variant.
            if envelope.type == "session_left" {
                return .sessionLeft(SessionLeftPayload(sessionId: nil, reason: nil, detail: nil))
            }
            print("[WS] No payload for type: \(envelope.type)")
            return nil
        }

        let decoder = JSONDecoder()

        do {
            switch envelope.type {
            case "state_update":
                return .stateUpdate(try decoder.decode(StateUpdatePayload.self, from: payloadData))
            case "text":
                return .text(try decoder.decode(TextPayload.self, from: payloadData))
            case "handoff":
                return .handoff(try decoder.decode(HandoffPayload.self, from: payloadData))
            case "session_entered":
                return .sessionEntered(try decoder.decode(SessionEnteredPayload.self, from: payloadData))
            case "session_left":
                return .sessionLeft(try decoder.decode(SessionLeftPayload.self, from: payloadData))
            case "session_history":
                return .sessionHistory(try decoder.decode(SessionHistoryPayload.self, from: payloadData))
            case "session_named":
                return .sessionNamed(try decoder.decode(SessionNamedPayload.self, from: payloadData))
            case "session_renamed":
                return .sessionRenamed(try decoder.decode(SessionRenamedPayload.self, from: payloadData))
            case "session_labels_updated":
                return .sessionLabelsUpdated(try decoder.decode(SessionLabelsUpdatedPayload.self, from: payloadData))
            case "session_deleted":
                return .sessionDeleted(try decoder.decode(SessionDeletedPayload.self, from: payloadData))
            case "session_unread":
                return .sessionUnread(try decoder.decode(SessionUnreadPayload.self, from: payloadData))
            case "session_status":
                return .sessionStatus(try decoder.decode(SessionStatusPayload.self, from: payloadData))
            case "text_start":
                return .textStart(try decoder.decode(TextStartPayload.self, from: payloadData))
            case "text_delta":
                return .textDelta(try decoder.decode(TextDeltaPayload.self, from: payloadData))
            case "text_done":
                return .textDone(try decoder.decode(TextDonePayload.self, from: payloadData))
            case "audio_start":
                return .audioStart(try decoder.decode(AudioStartPayload.self, from: payloadData))
            case "audio_chunk":
                return .audioChunk(try decoder.decode(AudioChunkPayload.self, from: payloadData))
            case "audio_done":
                return .audioDone(try decoder.decode(AudioDonePayload.self, from: payloadData))
            case "transcription":
                return .transcription(try decoder.decode(TranscriptionPayload.self, from: payloadData))
            case "agent_file":
                return .agentFile(try decoder.decode(AgentFilePayload.self, from: payloadData))
            case "project_file_changed":
                return .projectFileChanged(try decoder.decode(ProjectFileChangedPayload.self, from: payloadData))
            case "workspace_file_changed":
                return .workspaceFileChanged(try decoder.decode(WorkspaceFileChangedPayload.self, from: payloadData))
            case "compaction_started":
                return .compactionStarted(try decoder.decode(CompactionStartedPayload.self, from: payloadData))
            case "compaction_completed":
                return .compactionCompleted(try decoder.decode(CompactionCompletedPayload.self, from: payloadData))
            case "compaction_failed":
                return .compactionFailed(try decoder.decode(CompactionFailedPayload.self, from: payloadData))
            case "compaction_skipped":
                return .compactionSkipped(try decoder.decode(CompactionSkippedPayload.self, from: payloadData))
            case "agent_activity":
                return .agentActivity(try decoder.decode(AgentActivityPayload.self, from: payloadData))
            case "session_project_changed":
                return .sessionProjectChanged(try decoder.decode(SessionProjectChangedPayload.self, from: payloadData))
            case "session_error":
                return .sessionError(try decoder.decode(SessionErrorPayload.self, from: payloadData))
            case "error":
                return .error(try decoder.decode(ErrorPayload.self, from: payloadData))
            default:
                print("[WS] Unknown event type: \(envelope.type)")
                return nil
            }
        } catch {
            print("[WS] Failed to decode payload for \(envelope.type): \(error)")
            return nil
        }
    }
}

// MARK: - Helper for preserving raw payload JSON

struct AnyCodablePayload: Codable {
    let data: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Decode as a generic JSON structure, then re-encode to Data
        let jsonValue = try container.decode(JSONValue.self)
        self.data = try JSONEncoder().encode(jsonValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)
        try container.encode(jsonValue)
    }
}

/// Generic JSON value type. Used internally by `AnyCodablePayload` for
/// round-tripping raw payload JSON, and by `SessionLeftPayload.detail`
/// (and any future payload that needs to carry an open-shaped object
/// without losing fidelity for diagnostics).
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    /// Coerce into the plain-Any form `ActivityLog`'s serialiser already
    /// knows how to print as JSON.
    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues(\.anyValue)
        case .array(let v): return v.map(\.anyValue)
        case .null: return NSNull()
        }
    }

    // ── Convenience lookups for object values ────────────────────────
    // Used by handlers that receive open-shaped payloads (e.g.
    // AgentActivityPayload.detail) and want to pluck named fields
    // without unwrapping the whole enum by hand.

    func valueForKey(_ key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    func stringForKey(_ key: String) -> String? {
        if case .string(let s) = valueForKey(key) ?? .null { return s }
        return nil
    }

    func boolForKey(_ key: String) -> Bool? {
        if case .bool(let b) = valueForKey(key) ?? .null { return b }
        return nil
    }
}

// MARK: - Client → Server events

enum ClientEvent {
    case textInput(text: String)
    case audioInput(data: String, format: String)
    case leaveSession
    case resumeSession(sessionId: String)
    case interrupt
    case setLiveMode(enabled: Bool)
    case renameSession(sessionId: String, name: String)
    case updateSessionLabels(sessionId: String, labels: [String])
    /// Ask the backend to stop the currently-running turn on this ark
    /// session. Server sends ark's `stop`; ark cancels the turn and
    /// emits `done {stopped: true}` which rides back as
    /// `text_done {interrupted: true}` — the streaming bubble picks up
    /// the interrupted affordance via the normal text_done path.
    case stopSession(sessionId: String)

    func toJSON() -> String? {
        let dict: [String: Any]
        switch self {
        case .textInput(let text):
            dict = ["type": "text_input", "payload": ["text": text]]
        case .audioInput(let data, let format):
            dict = ["type": "audio_input", "payload": ["data": data, "format": format]]
        case .leaveSession:
            dict = ["type": "leave_session"]
        case .resumeSession(let sessionId):
            dict = ["type": "resume_session", "payload": ["session_id": sessionId]]
        case .interrupt:
            dict = ["type": "interrupt", "payload": [:]]
        case .setLiveMode(let enabled):
            dict = ["type": "set_live_mode", "payload": ["enabled": enabled]]
        case .renameSession(let sessionId, let name):
            dict = ["type": "rename_session", "payload": ["session_id": sessionId, "name": name]]
        case .updateSessionLabels(let sessionId, let labels):
            dict = ["type": "update_session_labels", "payload": ["session_id": sessionId, "labels": labels]]
        case .stopSession(let sessionId):
            dict = ["type": "stop_session", "payload": ["session_id": sessionId]]
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: jsonData, encoding: .utf8)
    }
}
