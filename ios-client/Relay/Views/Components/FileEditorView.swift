import SwiftUI
#if canImport(UIKit)
import UIKit
import PDFKit
#endif

/// Full-pane file editor used by the iPad central-area tab system. Loads
/// the file on mount, lets the user edit in a Runestone-backed editor,
/// and saves the draft via the existing API. Detects on-disk changes via
/// `fileChanges` — quiet reload when the user isn't dirty, prompt-style
/// banner when they are.
///
/// Mirrors the web `FileEditorTab` in shape so the two stay in parity.
struct FileEditorView: View {
    let relay: RelayViewModel
    let kind: APIClient.FsKind
    let targetId: String
    let path: String
    let server: String?
    /// `project_id` for project files, ark `agent_name` for workspaces.
    /// Used to match `fileChanges` events to this file.
    let scope: String
    /// Lifted up so the iPad tab bar can render the dirty dot.
    let onDirtyChange: (Bool) -> Void

    @Environment(\.relayTheme) private var theme

    @State private var savedContent: String?
    @State private var isDirty = false
    /// Bumped on each successful load / save. Tells the editor to
    /// install `savedContent` as a fresh clean baseline.
    @State private var editorCleanVersion = 0
    /// Read-back surface into the editor's live buffer. Used on save to
    /// pull the current text without forcing a per-keystroke binding.
    @State private var handle = EditorTextHandle()
    @State private var isBinary = false
    @State private var loading = true
    @State private var error: String?
    @State private var saving = false
    @State private var staleBanner = false
    /// Persisted across files (and app launches) — most users want the
    /// same wrap behavior in every editor they open. Defaults to ON;
    /// matches the web client's default.
    @AppStorage("relay_editor_wrap") private var wrap: Bool = true
    /// True when the file isn't currently on disk — either it 404'd on
    /// load or a delete event arrived. The tab stays open, the draft is
    /// kept, and Save recreates the file.
    @State private var notOnDisk = false
    /// Decoded image bytes for image-typed files.
    #if canImport(UIKit)
    @State private var image: UIImage? = nil
    /// Raw PDF bytes; PDFKit's PDFView renders them inline.
    @State private var pdfData: Data? = nil
    #endif
    @State private var lastSeenFileChangeTs: Date = .distantPast

    /// Bumped to ask `SelectableTextEditor` to present Runestone's
    /// built-in UIFindInteraction (system find navigator).
    @State private var findTrigger = 0

    /// View/edit toggle for markdown files. Opens in "view" for a
    /// clean read; toggle enters "edit" for the occasional tweak.
    /// Per-tab state (no cross-session persistence). See `_mdMode`
    /// helper below for the actual value used at render — a
    /// notOnDisk file (fresh, nothing to preview) is always forced
    /// to edit regardless of this flag.
    @State private var mode: MarkdownMode = .view
    /// Snapshot of the editor's live buffer at the moment the user
    /// toggled to view mode. Rendered as the preview. Not
    /// continuously updated in view mode — the editor is unmounted
    /// there, so there's nothing to update from. The snapshot
    /// approach means "I see what I typed, just laid out" holds at
    /// the moment of toggle, which is what matters.
    @State private var previewText: String = ""

    enum MarkdownMode { case view, edit }

    /// Effective mode after applying the "notOnDisk → force edit"
    /// override. Use this everywhere we branch on the mode.
    private var effectiveMode: MarkdownMode {
        (isMarkdown && !notOnDisk) ? mode : .edit
    }

    private var isImageMode: Bool {
        #if canImport(UIKit)
        return image != nil
        #else
        return false
        #endif
    }

    private var isPdfMode: Bool {
        #if canImport(UIKit)
        return pdfData != nil
        #else
        return false
        #endif
    }

    private var filename: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// True when this file is a markdown document — drives the
    /// visibility of the view/edit toggle and defaults `mode` to
    /// "view" on open. Extension-based classification, same as web.
    private var isMarkdown: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if staleBanner {
                staleBannerView
            } else if notOnDisk {
                notOnDiskBanner
            }
            if let err = error {
                Text(err)
                    .font(theme.monoFont(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.surface)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.elevated)
        .task(id: path) { await loadFile() }
        .onChange(of: relay.fileChanges.count) { _, _ in handleFileChange() }
        .onChange(of: isDirty) { _, newValue in onDirtyChange(newValue) }
        // ⌘F to open the find bar (no-op when an external keyboard isn't
        // attached, and harmless on iPhone).
        .background(
            Button("") { openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private func openFind() {
        guard !isBinary, !isImageMode, !isPdfMode else { return }
        findTrigger &+= 1
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Text(path)
                .font(theme.monoFont(size: 12))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            // Preview toggle (markdown only). Its highlighted state
            // means preview is showing; unselected means raw editor.
            // Preview and Edit aren't opposites — Save/Reload apply
            // regardless of which is visible. Find/Wrap only apply to
            // the editor, so those grey out below when preview is on.
            if isMarkdown && !notOnDisk && !isBinary && !loading && !isImageMode && !isPdfMode {
                Button {
                    if effectiveMode == .edit {
                        // Snapshot the live buffer so the preview
                        // reflects what the user typed, not on-disk.
                        previewText = handle.currentText
                        mode = .view
                    } else {
                        mode = .edit
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 15))
                }
                .foregroundStyle(effectiveMode == .view ? theme.primary : theme.textSecondary)
                .help(effectiveMode == .view ? "Hide rendered preview" : "Show rendered preview")
            }
            // Find and Wrap only affect the editor — disable them in
            // preview mode. Save + Reload stay enabled either way
            // (Save writes the live buffer regardless of what's on
            // screen; Reload throws away buffer state either way).
            if !isBinary && !loading && !isImageMode && !isPdfMode {
                let editorHidden = effectiveMode != .edit
                Button { openFind() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                }
                .disabled(editorHidden)
                .foregroundStyle(editorHidden ? theme.textQuaternary : theme.textSecondary)
                .help(editorHidden
                      ? "Find — switch to editor to use"
                      : "Find in file (⌘F)")
                Button { wrap.toggle() } label: {
                    Image(systemName: wrap ? "arrow.turn.down.left" : "arrow.right.to.line")
                        .font(.system(size: 15))
                }
                .disabled(editorHidden)
                .foregroundStyle(
                    editorHidden
                        ? theme.textQuaternary
                        : (wrap ? theme.primary : theme.textSecondary),
                )
                .help(editorHidden
                      ? "Word wrap — switch to editor to use"
                      : (wrap ? "Turn off word wrap" : "Turn on word wrap"))
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 15))
                    }
                }
                .disabled(!isDirty || saving)
                .foregroundStyle(isDirty ? theme.success : theme.textQuaternary)
                .help(saving ? "Saving…" : (isDirty ? "Save changes to disk" : "Nothing to save"))
            }
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15))
            }
            .disabled(loading)
            .foregroundStyle(theme.textSecondary)
            .help("Reload from disk (discards unsaved changes)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
    }

    @ViewBuilder
    private var notOnDiskBanner: some View {
        Text("File doesn't exist on disk — save to create it.")
            .font(theme.bodyFont(size: 12))
            .foregroundStyle(theme.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.primary.opacity(0.12))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.primary.opacity(0.3)).frame(height: theme.borderWidth)
            }
    }

    @ViewBuilder
    private var staleBannerView: some View {
        HStack {
            Text("File changed on disk while you were editing.")
                .font(theme.bodyFont(size: 12))
                .foregroundStyle(theme.warning)
            Spacer()
            Button("Reload (discards changes)") {
                Task { await loadFile() }
            }
            .foregroundStyle(theme.warning)
            .fontWeight(.semibold)
            Button("Keep my changes") {
                staleBanner = false
            }
            .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.warning.opacity(0.15))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.warning.opacity(0.4)).frame(height: theme.borderWidth)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack { ProgressView(); Spacer() }
                .padding()
        } else if isImageMode {
            #if canImport(UIKit)
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(theme.surface)
            }
            #endif
        } else if isPdfMode {
            #if canImport(UIKit)
            if let data = pdfData {
                PDFKitView(data: data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface)
            }
            #endif
        } else if isBinary {
            Text("Binary file — download it from the file browser.")
                .font(theme.bodyFont(size: 13))
                .foregroundStyle(theme.textQuaternary)
                .italic()
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let saved = savedContent {
            #if canImport(UIKit)
            // The editor stays mounted at all times so its Runestone
            // buffer keeps the user's unsaved draft across mode
            // toggles — remounting resets `v.text = cleanText` and
            // would nuke the draft on every switch back to edit.
            // View mode overlays a scrollable MarkdownText on top.
            ZStack {
                SelectableTextEditor(
                    handle: handle,
                    cleanText: saved,
                    cleanVersion: editorCleanVersion,
                    wrap: wrap,
                    onDirtyChange: { isDirty = $0 },
                    onFocusChange: { relay.editorFocused = $0 },
                    resignTrigger: relay.resignEditorFocusTrigger,
                    findTrigger: findTrigger,
                )
                .background(theme.elevated)
                .opacity(effectiveMode == .view ? 0 : 1)
                .allowsHitTesting(effectiveMode == .edit)
                if effectiveMode == .view {
                    // `previewText` was snapshotted at toggle time
                    // (from `handle.currentText`). On the initial
                    // open — markdown files default to view and we
                    // haven't toggled yet — fall back to `saved`.
                    ScrollView {
                        MarkdownText(text: previewText.isEmpty ? saved : previewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .background(theme.elevated)
                }
            }
            #else
            Text("Editor unavailable on this platform.")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .padding()
            #endif
        }
    }

    private func loadFile() async {
        loading = true
        error = nil
        isBinary = false
        staleBanner = false
        #if canImport(UIKit)
        image = nil
        pdfData = nil
        #endif
        defer { loading = false }
        do {
            let (data, response) = try await relay.apiClient.readFile(
                kind, id: targetId, path: path, server: server,
            )
            let ct = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isText = ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") || _hasTextExt(path)
            let isImage = ct.hasPrefix("image/") || (!isText && _hasImageExt(path))
            let isPdf = ct == "application/pdf" || (!isText && !isImage && _hasPdfExt(path))
            if isText {
                let text = String(data: data, encoding: .utf8) ?? ""
                savedContent = text
                editorCleanVersion &+= 1
                isDirty = false
            } else if isImage {
                #if canImport(UIKit)
                image = UIImage(data: data)
                if image == nil {
                    // Failed to decode — fall back to binary message.
                    isBinary = true
                }
                #else
                isBinary = true
                #endif
                savedContent = nil
            } else if isPdf {
                #if canImport(UIKit)
                pdfData = data
                #else
                isBinary = true
                #endif
                savedContent = nil
            } else {
                isBinary = true
                savedContent = nil
            }
            notOnDisk = false
        } catch APIClient.APIError.httpError(404) {
            // Treat the tab as a "new file." If the editor was already
            // mounted (reload-while-mounted 404 or post-delete reload),
            // the user's in-progress buffer is preserved — flag dirty so
            // save is enabled and they can recreate the file. On the
            // initial-mount 404 path, the buffer just starts empty.
            let wasMounted = savedContent != nil
            savedContent = ""
            isBinary = false
            notOnDisk = true
            if wasMounted { isDirty = true } else { isDirty = false }
        } catch {
            self.error = String(describing: error)
        }
    }

    private func reload() async {
        if isDirty {
            // Best-effort confirm on iPad: there's no native confirm dialog
            // mid-view, so we just discard. The stale-banner path already
            // gives the user an explicit choice when relevant.
            await loadFile()
        } else {
            await loadFile()
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            // Pull the live buffer once at save time — the only place we
            // need to materialize the Runestone piece tree into a String.
            let text = handle.currentText
            try await relay.apiClient.writeFile(
                kind, id: targetId, path: path,
                body: text.data(using: .utf8) ?? Data(), server: server,
            )
            savedContent = text
            editorCleanVersion &+= 1
            isDirty = false
            staleBanner = false
            notOnDisk = false
        } catch {
            self.error = String(describing: error)
        }
    }

    /// React to a disk-side change to this exact file. Delete → transition
    /// to "not on disk" (draft preserved). Create/modify → quiet reload
    /// when clean, stale banner when dirty.
    private func handleFileChange() {
        let matches = relay.fileChanges.filter { ev in
            ev.kind.rawValue == (kind == .project ? "project" : "workspace")
            && ev.scope == scope
            && ev.path == path
            && ev.ts > lastSeenFileChangeTs
        }
        guard !matches.isEmpty else { return }
        lastSeenFileChangeTs = matches.map(\.ts).max() ?? lastSeenFileChangeTs
        // Sort by ts so `last` is reliable across batches.
        let sorted = matches.sorted(by: { $0.ts < $1.ts })
        if sorted.last?.change == .deleted {
            savedContent = ""
            notOnDisk = true
            staleBanner = false
            // The editor still holds the user's work; flag dirty so save
            // is enabled and they can re-create the file by saving.
            isDirty = true
            return
        }
        if isDirty {
            staleBanner = true
        } else {
            Task { await loadFile() }
        }
    }
}

func _hasTextExt(_ path: String) -> Bool {
    let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
    return [
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "ini", "cfg",
        "csv", "tsv", "log", "py", "js", "ts", "tsx", "jsx", "swift", "go",
        "rs", "rb", "java", "c", "h", "cpp", "hpp", "cs", "sh", "bash", "zsh",
        "css", "scss", "html", "xml", "sql", "env", "gitignore",
    ].contains(ext)
}

func _hasPdfExt(_ path: String) -> Bool {
    let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
    return ext == "pdf"
}

/// True when this file type can be previewed in-app (text editor,
/// image, or PDF). Used at file-load time to route the raw bytes.
func isPreviewableFile(_ path: String) -> Bool {
    return _hasTextExt(path) || _hasImageExt(path) || _hasPdfExt(path)
}

/// Extensions we're confident are binary — used for row icons only.
/// Extensionless files like README/Dockerfile/Makefile land in the
/// "unknown" bucket and stay neutral in the browser row; the byte-level
/// probe on click is the real gate.
private let _KNOWN_BINARY_EXTS: Set<String> = [
    "exe", "dll", "so", "dylib", "class", "jar", "wasm", "o", "a", "lib",
    "bin", "dat", "iso",
    "zip", "tar", "tgz", "gz", "bz2", "xz", "7z", "rar",
    "mp3", "mp4", "mov", "mkv", "avi", "webm", "wav", "flac", "ogg", "m4a",
    "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
    "psd", "ai", "sketch", "fig",
    "ttf", "otf", "woff", "woff2", "eot",
]

func isKnownBinaryExt(_ path: String) -> Bool {
    let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
    return _KNOWN_BINARY_EXTS.contains(ext)
}

func _hasImageExt(_ path: String) -> Bool {
    let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
    return [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff",
        "heic", "heif", "ico", "svg", "avif",
    ].contains(ext)
}

#if canImport(UIKit)
/// Thin SwiftUI wrapper around PDFKit's `PDFView` so a PDF file's bytes
/// can be shown inline in the editor tab. Auto-scales to fit width.
struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.document = PDFDocument(data: data)
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        // Rebuild only if bytes change — comparing NSData identity
        // avoids a full re-parse on unrelated re-renders.
        if v.document?.dataRepresentation() != data {
            v.document = PDFDocument(data: data)
        }
    }
}
#endif
