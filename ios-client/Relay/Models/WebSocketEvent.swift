import Foundation

// MARK: - Server → Client events

enum WebSocketEvent {
    case stateUpdate(StateUpdatePayload)
    case text(TextPayload)
    case handoff(HandoffPayload)
    case sessionEntered(SessionEnteredPayload)
    case sessionLeft
    case sessionHistory(SessionHistoryPayload)
    case sessionNamed(SessionNamedPayload)
    case textStart(TextStartPayload)
    case textDelta(TextDeltaPayload)
    case textDone(TextDonePayload)
    case audioStart(AudioStartPayload)
    case audioChunk(AudioChunkPayload)
    case audioDone(AudioDonePayload)
    case transcription(TranscriptionPayload)
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

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentName = "agent_name"
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
            // Some events (like leave_session response) may have no payload
            if envelope.type == "session_left" { return .sessionLeft }
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
                return .sessionLeft
            case "session_history":
                return .sessionHistory(try decoder.decode(SessionHistoryPayload.self, from: payloadData))
            case "session_named":
                return .sessionNamed(try decoder.decode(SessionNamedPayload.self, from: payloadData))
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

// Generic JSON value type for re-encoding payloads
private enum JSONValue: Codable {
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
}

// MARK: - Client → Server events

enum ClientEvent {
    case textInput(text: String)
    case audioInput(data: String, format: String)
    case leaveSession
    case resumeSession(sessionId: String)
    case interrupt
    case setLiveMode(enabled: Bool)

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
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: jsonData, encoding: .utf8)
    }
}
