import Foundation

/// Single-threaded chronological log of app lifecycle events for debugging.
/// Events are kept in-memory only; cleared on app relaunch.
@Observable
@MainActor
final class ActivityLog {
    static let shared = ActivityLog()

    private static let maxEvents = 500

    private(set) var events: [ActivityEvent] = []

    func add(_ name: String, context: [String: Any] = [:]) {
        let event = ActivityEvent(
            id: UUID(),
            timestamp: Date(),
            name: name,
            contextJSON: Self.serialise(context)
        )
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

    func clear() { events.removeAll() }

    /// Pretty-printed dump of every recorded event (for copy-to-clipboard).
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return events.map { event in
            "[\(formatter.string(from: event.timestamp))] \(event.name)\n\(event.contextJSON)"
        }.joined(separator: "\n\n")
    }

    private static func serialise(_ context: [String: Any]) -> String {
        guard !context.isEmpty else { return "{}" }
        // JSONSerialization can't handle arbitrary types — coerce to JSON-safe.
        let safe = context.mapValues { Self.coerce($0) }
        guard
            let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
            let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func coerce(_ value: Any) -> Any {
        // Unwrap optionals so an `Any?` carrying a real value doesn't fall
        // through to NSNull just because the static type was Optional.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let inner = mirror.children.first?.value { return coerce(inner) }
            return NSNull()
        }
        switch value {
        case let v as String: return v
        case let v as Int: return v
        case let v as Double: return v
        case let v as Bool: return v
        case let v as UUID: return v.uuidString
        case let v as Date: return ISO8601DateFormatter().string(from: v)
        case let v as [Any]: return v.map(coerce)
        case let v as [String: Any]: return v.mapValues(coerce)
        default: return String(describing: value)
        }
    }
}

struct ActivityEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let name: String
    let contextJSON: String
}
