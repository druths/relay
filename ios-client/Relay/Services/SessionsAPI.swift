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

    /// Body shape for `PATCH /v1/sessions/{id}/project`. `projectId: nil`
    /// detaches the session; a uuid reassigns (or first-time-assigns) to
    /// that project on the same ark server the session's agent is bound
    /// to. Uses a manual init so we can serialise `nil` as JSON `null`
    /// (default `JSONEncoder` omits nil-valued optional keys, which the
    /// backend would then read as "no change requested" → 400).
    private struct SetProjectBody: Encodable {
        let projectId: String?
        enum CodingKeys: String, CodingKey { case projectId = "project_id" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let projectId {
                try c.encode(projectId, forKey: .projectId)
            } else {
                try c.encodeNil(forKey: .projectId)
            }
        }
    }

    /// Assign, reassign, or detach this session's ark project binding.
    /// Backend proxies to ark's `PATCH /agents/{name}/sessions/{sid}/project`
    /// and returns the updated `Session` row. A `session_project_changed`
    /// WS event fires on any real change (no-ops are silent), which the
    /// view-model uses to update chips + drop a divider into the
    /// transcript.
    func setSessionProject(
        _ sessionId: String, projectId: String?,
    ) async throws -> Session {
        return try await request(
            "PATCH",
            path: "/v1/sessions/\(sessionId)/project",
            body: SetProjectBody(projectId: projectId),
        )
    }

    private struct EmptyBody: Encodable {}
}
