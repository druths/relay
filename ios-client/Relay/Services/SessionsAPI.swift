import Foundation

extension APIClient {
    struct CompactResult: Decodable {
        let ok: Bool
        let summary: String?
        let reason: String?
    }

    /// Trigger ark session compaction. The visible UI update ("compacting…"
    /// chip on, then divider added on completion) arrives via the WS event
    /// stream, not this call's return value. Ark runs the actual work
    /// synchronously inside the POST though, so the request itself may
    /// take a few seconds — callers should not block their UI on it.
    func compactSession(_ sessionId: String) async throws -> CompactResult {
        return try await request(
            "POST",
            path: "/v1/sessions/\(sessionId)/compact",
            body: EmptyBody(),
        )
    }

    private struct EmptyBody: Encodable {}
}
