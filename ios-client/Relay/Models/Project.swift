import Foundation

/// An ark project, fetched through the Relay passthrough at `/v1/projects`.
/// `serverId` is the normalized base URL of the ark backend that hosts the
/// project — set server-side by the aggregator so single-project ops can be
/// routed back to the right ark.
struct Project: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var description: String?
    var projectContext: String?
    var root: String?
    /// Epoch milliseconds — ark serializes these as ints (see `ark/types.py`).
    /// Earlier this was typed as `String?`, which made the whole list-decode
    /// fail silently and the UI looked empty even when projects existed.
    var createdAt: Int?
    var deletedAt: Int?
    var serverId: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case projectContext = "project_context"
        case root
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case serverId = "server_id"
    }
}

/// One entry from `GET /v1/projects/{id}/files/...` or
/// `GET /v1/agents/{id}/workspace/files/...`.
struct DirEntry: Codable, Identifiable, Equatable {
    let name: String
    let isDir: Bool
    let size: Int
    let mtime: Int

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isDir = "is_dir"
        case size
        case mtime
    }
}

struct DirListing: Codable, Equatable {
    let path: String
    let entries: [DirEntry]
}

/// Live file-change event surfaced by ark over the unified WS, forwarded
/// verbatim by Relay. Kept in a short ring buffer on the view-model so the
/// file browser can render a "Recent changes" feed without polling.
struct FileChangeEvent: Equatable, Identifiable {
    enum Kind: String { case project, workspace }
    enum Change: String, Codable { case created, modified, deleted }

    let ts: Date
    let kind: Kind
    let scope: String   // projectId for .project, agentName for .workspace
    let path: String
    let change: Change

    var id: String { "\(ts.timeIntervalSince1970)-\(kind.rawValue)-\(scope)-\(path)" }
}

/// `{server_id, base_url}` from `GET /v1/projects/servers` — the ark
/// backends Relay knows about, used to populate the create-project picker
/// when more than one is configured.
struct ArkServerInfo: Codable, Equatable {
    let serverId: String
    let baseUrl: String

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case baseUrl = "base_url"
    }
}
