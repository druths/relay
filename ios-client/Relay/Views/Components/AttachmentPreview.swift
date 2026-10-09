import SwiftUI
import UIKit

/// Dispatches a `FileAttachment` to one of three renderers based on
/// MIME / extension:
///   • `image/*`                     → inline thumbnail (capped size)
///   • `text/*` + extension allowlist → first ~1500 chars
///   • everything else               → the legacy pill
///
/// All three variants carry a filename+size caption line underneath
/// so the download/open affordance stays discoverable, and expose
/// the same context-menu actions (Open / Preview / Share) so users
/// can right-click/long-press to reach them.
struct AttachmentPreview: View {
    let attachment: FileAttachment
    var onOpen: ((FileAttachment) -> Void)? = nil

    var body: some View {
        if _AttachmentType.detect(attachment) == .image {
            ImageAttachmentPreview(attachment: attachment, onOpen: onOpen)
        } else if _AttachmentType.detect(attachment) == .text {
            TextAttachmentPreview(attachment: attachment, onOpen: onOpen)
        } else {
            AttachmentPill(attachment: attachment, onOpen: onOpen)
        }
    }
}

// MARK: - Type detection

private enum _AttachmentType {
    case image, text, other

    static func detect(_ a: FileAttachment) -> _AttachmentType {
        if a.mimeType.hasPrefix("image/") { return .image }
        if a.mimeType.hasPrefix("text/") { return .text }
        let ext = (a.filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty && _textPreviewExts.contains(ext) { return .text }
        return .other
    }
}

/// Extensions that get a text preview even when the server reports a
/// non-`text/*` MIME (common for `.md`, `.py`, etc. served as
/// `application/octet-stream`).
private let _textPreviewExts: Set<String> = [
    "txt", "md", "markdown", "py", "js", "jsx", "ts", "tsx",
    "swift", "json", "yaml", "yml", "toml", "html", "htm", "css",
    "sh", "zsh", "sql", "csv", "log", "ini", "cfg", "conf",
    "rb", "go", "rs", "c", "h", "cpp", "hpp", "java", "kt",
    "xml", "env", "gitignore",
]

// MARK: - Shared helpers (URL, size label, caption, context menu)

private func _fullURL(for attachment: FileAttachment) -> URL? {
    if attachment.url.hasPrefix("http") { return URL(string: attachment.url) }
    return URL(string: "\(AppConfig.apiBase)\(attachment.url)")
}

private func _sizeLabel(_ bytes: Int) -> String? {
    guard bytes > 0 else { return nil }
    let b = Double(bytes)
    if b < 1024 { return "\(Int(b)) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
    return String(format: "%.1f MB", b / 1024 / 1024)
}

/// Download the attachment data with auth. Returns `nil` on failure
/// or non-2xx. Shared by the image loader and the text-preview
/// fetcher so both go through the same auth path.
private func _fetchAttachmentData(_ attachment: FileAttachment) async -> Data? {
    guard let url = _fullURL(for: attachment) else { return nil }
    var request = URLRequest(url: url)
    if let token = KeychainService.load() {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return data
    } catch {
        return nil
    }
}

/// Process-wide cache of fetched attachment bytes, keyed by the
/// attachment's effective URL. Cheap to re-render bubbles on
/// scroll without re-downloading. Capped by NSCache's cost
/// heuristics; iOS evicts under memory pressure.
private final class _AttachmentDataCache: @unchecked Sendable {
    static let shared = _AttachmentDataCache()
    private let cache = NSCache<NSString, NSData>()

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024  // ~32 MB
    }

    func get(key: String) -> Data? {
        cache.object(forKey: key as NSString) as Data?
    }

    func set(key: String, data: Data) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}

private func _cachedOrFetch(_ attachment: FileAttachment) async -> Data? {
    let key = attachment.url
    if let cached = _AttachmentDataCache.shared.get(key: key) { return cached }
    guard let data = await _fetchAttachmentData(attachment) else { return nil }
    _AttachmentDataCache.shared.set(key: key, data: data)
    return data
}

// MARK: - Image preview

private struct ImageAttachmentPreview: View {
    let attachment: FileAttachment
    var onOpen: ((FileAttachment) -> Void)?

    @Environment(\.relayTheme) private var theme
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var previewURL: FileURLRef?
    @State private var shareURL: FileURLRef?
    @State private var downloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            previewArea
                .contextMenu { attachmentMenu }
            captionLine
        }
        .task { await loadImage() }
        .sheet(item: $previewURL) { wrapped in
            QuickLookPreview(url: wrapped.url).ignoresSafeArea()
        }
        .sheet(item: $shareURL) { wrapped in
            ShareSheet(url: wrapped.url)
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if let img = image {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.border, lineWidth: theme.borderWidth),
                )
                .onTapGesture { Task { await openPreview() } }
        } else if isLoading {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .fill(theme.elevated)
                .frame(width: 240, height: 160)
                .overlay { ProgressView().tint(theme.textQuaternary) }
        } else {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .fill(theme.elevated)
                .frame(width: 240, height: 160)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(theme.textQuaternary)
                        Text("Couldn't load image")
                            .font(theme.monoFont(size: 11))
                            .foregroundStyle(theme.textQuaternary)
                    },
                )
        }
    }

    private var captionLine: some View {
        AttachmentCaption(
            attachment: attachment,
            downloading: downloading,
            onTap: { Task { await openPreview() } },
        )
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        AttachmentContextMenuItems(
            attachment: attachment,
            onOpen: onOpen,
            onPreview: { Task { await openPreview() } },
            onShare: { Task { await openShare() } },
        )
    }

    private func loadImage() async {
        guard image == nil else { return }
        guard let data = await _cachedOrFetch(attachment),
              let img = UIImage(data: data) else {
            await MainActor.run { isLoading = false }
            return
        }
        await MainActor.run {
            self.image = img
            self.isLoading = false
        }
    }

    private func openPreview() async {
        if let url = await _downloadToTemp(attachment, downloading: $downloading) {
            await MainActor.run { previewURL = FileURLRef(url: url) }
        }
    }

    private func openShare() async {
        if let url = await _downloadToTemp(attachment, downloading: $downloading) {
            await MainActor.run { shareURL = FileURLRef(url: url) }
        }
    }
}

// MARK: - Text preview

private struct TextAttachmentPreview: View {
    let attachment: FileAttachment
    var onOpen: ((FileAttachment) -> Void)?

    @Environment(\.relayTheme) private var theme
    @State private var preview: String?
    @State private var truncated = false
    @State private var isLoading = true
    @State private var previewURL: FileURLRef?
    @State private var shareURL: FileURLRef?
    @State private var downloading = false

    private static let maxChars = 1500
    private static let maxLines = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            previewArea
                .contextMenu { attachmentMenu }
            captionLine
        }
        .task { await loadText() }
        .sheet(item: $previewURL) { wrapped in
            QuickLookPreview(url: wrapped.url).ignoresSafeArea()
        }
        .sheet(item: $shareURL) { wrapped in
            ShareSheet(url: wrapped.url)
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if let preview {
            Text(preview)
                .font(theme.monoFont(size: 12))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme.elevated)
                .overlay(alignment: .bottom) {
                    // Faded gradient when the file was truncated —
                    // signals there's more content below the fold.
                    if truncated {
                        LinearGradient(
                            colors: [theme.elevated.opacity(0), theme.elevated],
                            startPoint: .top,
                            endPoint: .bottom,
                        )
                        .frame(height: 24)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(theme.border, lineWidth: theme.borderWidth),
                )
                .frame(maxWidth: 480)
                .onTapGesture { _onTextTap() }
        } else if isLoading {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .fill(theme.elevated)
                .frame(width: 240, height: 80)
                .overlay { ProgressView().tint(theme.textQuaternary) }
        } else {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .fill(theme.elevated)
                .frame(width: 240, height: 60)
                .overlay(
                    Text("Couldn't load preview")
                        .font(theme.monoFont(size: 11))
                        .foregroundStyle(theme.textQuaternary),
                )
        }
    }

    private var captionLine: some View {
        AttachmentCaption(
            attachment: attachment,
            downloading: downloading,
            onTap: { _onTextTap() },
        )
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        AttachmentContextMenuItems(
            attachment: attachment,
            onOpen: onOpen,
            onPreview: { Task { await openPreview() } },
            onShare: { Task { await openShare() } },
        )
    }

    /// On tap, prefer the editor if the attachment has a
    /// workspace/project ref; otherwise fall through to Quick Look.
    /// Mirrors the pill's behaviour.
    private func _onTextTap() {
        if let onOpen, attachment.kind != nil, attachment.path != nil {
            onOpen(attachment)
            return
        }
        Task { await openPreview() }
    }

    private func loadText() async {
        guard preview == nil else { return }
        guard let data = await _cachedOrFetch(attachment),
              let str = String(data: data, encoding: .utf8) else {
            await MainActor.run { isLoading = false }
            return
        }
        let (snippet, wasTruncated) = _truncatePreview(str)
        await MainActor.run {
            self.preview = snippet
            self.truncated = wasTruncated
            self.isLoading = false
        }
    }

    private func _truncatePreview(_ s: String) -> (String, Bool) {
        var lines: [String] = []
        var charCount = 0
        var truncatedFlag = false
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= Self.maxLines {
                truncatedFlag = true
                break
            }
            if charCount + line.count > Self.maxChars {
                let remaining = Self.maxChars - charCount
                if remaining > 0 {
                    lines.append(String(line.prefix(remaining)))
                }
                truncatedFlag = true
                break
            }
            lines.append(String(line))
            charCount += line.count + 1
        }
        return (lines.joined(separator: "\n"), truncatedFlag)
    }

    private func openPreview() async {
        if let url = await _downloadToTemp(attachment, downloading: $downloading) {
            await MainActor.run { previewURL = FileURLRef(url: url) }
        }
    }

    private func openShare() async {
        if let url = await _downloadToTemp(attachment, downloading: $downloading) {
            await MainActor.run { shareURL = FileURLRef(url: url) }
        }
    }
}

// MARK: - Shared caption + context menu

private struct AttachmentCaption: View {
    let attachment: FileAttachment
    let downloading: Bool
    let onTap: () -> Void

    @Environment(\.relayTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if downloading {
                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
                Text(attachment.filename)
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let s = _sizeLabel(attachment.sizeBytes) {
                    Text("· \(s)")
                        .font(theme.monoFont(size: 11))
                        .foregroundStyle(theme.textQuaternary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

@MainActor
@ViewBuilder
private func AttachmentContextMenuItems(
    attachment: FileAttachment,
    onOpen: ((FileAttachment) -> Void)?,
    onPreview: @escaping @MainActor () -> Void,
    onShare: @escaping @MainActor () -> Void,
) -> some View {
    let canOpenInEditor = onOpen != nil
        && attachment.kind != nil
        && attachment.path != nil
    if canOpenInEditor, let onOpen {
        Button {
            onOpen(attachment)
        } label: {
            Label("Open", systemImage: "arrow.up.right.square")
        }
    }
    Button(action: onPreview) {
        Label("Preview", systemImage: "eye")
    }
    Button(action: onShare) {
        Label("Share…", systemImage: "square.and.arrow.up")
    }
}

// MARK: - Download helper

/// Shared download-to-temp used by image + text preview variants.
/// Pattern mirrors `AttachmentPill.downloadToTemp`; factored out so
/// the two new views and the legacy pill eventually converge on one
/// path (not done yet to keep this change contained).
private func _downloadToTemp(
    _ attachment: FileAttachment,
    downloading: Binding<Bool>,
) async -> URL? {
    guard let url = _fullURL(for: attachment) else { return nil }
    await MainActor.run { downloading.wrappedValue = true }
    defer { Task { @MainActor in downloading.wrappedValue = false } }

    var request = URLRequest(url: url)
    if let token = KeychainService.load() {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fileURL = tmp.appendingPathComponent(attachment.filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    } catch {
        return nil
    }
}
