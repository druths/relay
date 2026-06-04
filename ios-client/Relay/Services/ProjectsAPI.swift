import Foundation

/// Project + filesystem helpers that ride the existing `APIClient`. Keeps
/// the surface area discoverable without bloating APIClient.swift itself.
extension APIClient {

    // ── Projects CRUD ─────────────────────────────────────────────────

    func listProjects() async throws -> [Project] {
        try await request("GET", path: "/v1/projects")
    }

    func listArkServers() async throws -> [ArkServerInfo] {
        try await request("GET", path: "/v1/projects/servers")
    }

    struct ProjectCreateBody: Encodable {
        let name: String
        let description: String?
        let projectContext: String?
        let root: String?

        enum CodingKeys: String, CodingKey {
            case name, description, root
            case projectContext = "project_context"
        }
    }

    func createProject(
        server: String, name: String,
        description: String? = nil, projectContext: String? = nil, root: String? = nil,
    ) async throws -> Project {
        let path = "/v1/projects?server=\(_pct(server))"
        let body = ProjectCreateBody(
            name: name, description: description,
            projectContext: projectContext, root: root,
        )
        return try await request("POST", path: path, body: body)
    }

    struct ProjectUpdateBody: Encodable {
        let name: String?
        let description: String?
        let projectContext: String?

        enum CodingKeys: String, CodingKey {
            case name, description
            case projectContext = "project_context"
        }
    }

    func updateProject(
        projectId: String, server: String,
        name: String? = nil, description: String? = nil, projectContext: String? = nil,
    ) async throws -> Project {
        let path = "/v1/projects/\(projectId)?server=\(_pct(server))"
        let body = ProjectUpdateBody(
            name: name, description: description, projectContext: projectContext,
        )
        return try await request("PUT", path: path, body: body)
    }

    func deleteProject(projectId: String, server: String) async throws {
        try await delete(path: "/v1/projects/\(projectId)?server=\(_pct(server))")
    }

    // ── Sessions API (project-aware creation) ─────────────────────────

    struct SessionCreateBody: Encodable {
        let agentId: String
        let projectId: String?
        let projectServerId: String?
        let labels: [String]?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case agentId = "agent_id"
            case projectId = "project_id"
            case projectServerId = "project_server_id"
            case labels
            case name
        }
    }

    func createSession(
        agentId: String, projectId: String? = nil,
        projectServerId: String? = nil, labels: [String]? = nil,
        name: String? = nil,
    ) async throws -> Session {
        let body = SessionCreateBody(
            agentId: agentId, projectId: projectId,
            projectServerId: projectServerId, labels: labels,
            name: name?.trimmingCharacters(in: .whitespaces).isEmpty == false ? name : nil,
        )
        return try await request("POST", path: "/v1/sessions", body: body)
    }

    // ── Filesystem (project + workspace) ──────────────────────────────

    enum FsKind: String { case project, workspace }

    private func _fsBase(_ kind: FsKind, id: String, server: String?) -> (String, String) {
        switch kind {
        case .project:
            let q = server.map { "?server=\(_pct($0))" } ?? ""
            return ("/v1/projects/\(id)/files", q)
        case .workspace:
            return ("/v1/agents/\(id)/workspace/files", "")
        }
    }

    func listDir(_ kind: FsKind, id: String, path: String, server: String? = nil) async throws -> DirListing {
        let (base, q) = _fsBase(kind, id: id, server: server)
        let suffix = path.isEmpty ? "" : "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return try await request("GET", path: "\(base)\(suffix)\(q)")
    }

    func readFile(_ kind: FsKind, id: String, path: String, server: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let (base, q) = _fsBase(kind, id: id, server: server)
        return try await rawRequest(
            "GET",
            path: "\(base)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(q)",
        )
    }

    func writeFile(_ kind: FsKind, id: String, path: String, body: Data, server: String? = nil) async throws {
        let (base, q) = _fsBase(kind, id: id, server: server)
        let target = "\(base)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(q)"
        try await putRawBytes(path: target, body: body)
    }

    func deleteFile(_ kind: FsKind, id: String, path: String, server: String? = nil) async throws {
        let (base, q) = _fsBase(kind, id: id, server: server)
        try await delete(path: "\(base)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(q)")
    }

    func mkdir(_ kind: FsKind, id: String, path: String, server: String? = nil) async throws {
        let (base, q) = _fsBase(kind, id: id, server: server)
        let sep = q.isEmpty ? "?" : "&"
        let _ : EmptyResponse = try await request(
            "POST",
            path: "\(base)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(q)\(sep)op=mkdir",
        )
    }

    struct RenameBody: Encodable { let to: String }

    func renamePath(
        _ kind: FsKind, id: String, path: String, to: String, server: String? = nil,
    ) async throws {
        let (base, q) = _fsBase(kind, id: id, server: server)
        let sep = q.isEmpty ? "?" : "&"
        let _ : EmptyResponse = try await request(
            "POST",
            path: "\(base)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(q)\(sep)op=rename",
            body: RenameBody(to: to.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
        )
    }

    /// Downloads the path's bytes (zip for directories via `?op=zip`).
    /// Returns the raw data; the UI can hand it off to a share sheet so
    /// the user picks where to save / send.
    func downloadPath(
        _ kind: FsKind, id: String, path: String, isDir: Bool, server: String? = nil,
    ) async throws -> Data {
        let (base, q) = _fsBase(kind, id: id, server: server)
        let cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url: String
        if isDir {
            let sep = q.isEmpty ? "?" : "&"
            url = "\(base)/\(cleaned)\(q)\(sep)op=zip"
        } else {
            url = "\(base)/\(cleaned)\(q)"
        }
        let (data, _) = try await rawRequest("GET", path: url)
        return data
    }

    // ── helpers ───────────────────────────────────────────────────────

    nonisolated private func _pct(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

private struct EmptyResponse: Decodable {}
