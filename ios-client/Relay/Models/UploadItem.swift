import Foundation

/// Live state for a single upload — shared between the chat attach
/// flow and the file-browser upload flow so one visual strip can
/// render either. Each row tags itself with `origin` so a surface
/// can filter to just its own uploads. Mirrors the web
/// `UploadItem` shape from `frontend/src/types.ts`.
struct UploadItem: Identifiable, Equatable {
    enum Origin: String { case chat, browser }
    enum Status: String { case uploading, done, failed, cancelled }

    let id: UUID
    let origin: Origin
    let filename: String
    var sizeBytes: Int64
    var uploadedBytes: Int64
    var status: Status
    /// Populated when `status == .failed`.
    var error: String?
    /// Chat-origin: which Relay session this attaches into.
    let sessionId: String?
    /// Browser-origin: filesystem target.
    let target: Target?
    let startedAt: Date

    struct Target: Equatable {
        let kind: APIClient.FsKind
        let id: String
        let path: String
        let server: String?
    }
}
