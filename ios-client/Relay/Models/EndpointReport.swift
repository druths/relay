import Foundation

/// Structured diagnostic report returned by the backend's
/// `GET /v1/agents/{id}/endpoint-check`. Mirrors the dataclass in
/// `app/services/endpoint_check.py` 1:1 — see there for what each check
/// covers per provider.
struct EndpointReport: Codable, Sendable {
    let agentId: String
    let agentName: String
    let provider: String
    let model: String
    let baseUrl: String?
    let summaryStatus: SummaryStatus
    let summaryMessage: String
    let checks: [Check]
    let raw: [String: JSONValue]

    enum SummaryStatus: String, Codable, Sendable {
        case healthy, degraded, down
    }

    struct Check: Codable, Sendable, Identifiable {
        let name: String
        let status: Status
        let detail: String
        let elapsedMs: Int?
        let extra: [String: JSONValue]

        /// Unique ID for List/ForEach. Names can repeat (rare but possible
        /// across providers) so we fold detail in.
        var id: String { "\(name)|\(detail)" }

        enum Status: String, Codable, Sendable {
            case ok, warn, fail, skip
        }

        enum CodingKeys: String, CodingKey {
            case name, status, detail
            case elapsedMs = "elapsed_ms"
            case extra
        }
    }

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentName = "agent_name"
        case provider, model
        case baseUrl = "base_url"
        case summaryStatus = "summary_status"
        case summaryMessage = "summary_message"
        case checks, raw
    }
}
