import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-pane file editor used by the iPad central-area tab system. Loads
/// the file on mount, lets the user edit in a TextEditor, and saves the
/// draft via the existing API. Detects on-disk changes via `fileChanges`
/// — quiet reload when the user isn't dirty, prompt-style banner when
/// they are.
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
    @State private var draft: String = ""
    @State private var isBinary = false
    @State private var loading = true
    @State private var error: String?
    @State private var saving = false
    @State private var staleBanner = false
    /// True when the file isn't currently on disk — either it 404'd on
    /// load or a delete event arrived. The tab stays open, the draft is
    /// kept, and Save recreates the file.
    @State private var notOnDisk = false
    /// Decoded image bytes for image-typed files.
    #if canImport(UIKit)
    @State private var image: UIImage? = nil
    #endif
    @State private var lastSeenFileChangeTs: Date = .distantPast

    // ── Find ─────────────────────────────────────────────────────────
    @State private var findOpen = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var selectedRange = NSRange(location: 0, length: 0)
    /// Bumped to force `SelectableTextEditor` to scroll the current
    /// selection into view; separate from the binding so the user's own
    /// typing-driven selection updates don't trigger jumps.
    @State private var scrollTarget = 0
    @FocusState private var findFocused: Bool

    private var findMatches: [NSRange] {
        guard !findQuery.isEmpty, !draft.isEmpty else { return [] }
        let nsDraft = draft as NSString
        let needle = findQuery
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: nsDraft.length)
        while search.length > 0 {
            let r = nsDraft.range(of: needle, options: .caseInsensitive, range: search)
            if r.location == NSNotFound { break }
            out.append(r)
            let next = r.location + max(1, r.length)
            search = NSRange(location: next, length: max(0, nsDraft.length - next))
        }
        return out
    }

    private var isDirty: Bool {
        guard let saved = savedContent else { return false }
        return draft != saved
    }

    /// The match the editor should visibly highlight, if any. Nil when the
    /// find bar is closed or the query has no matches.
    private var currentFindMatch: NSRange? {
        guard findOpen, !findMatches.isEmpty, findIndex < findMatches.count else { return nil }
        return findMatches[findIndex]
    }

    private var isImageMode: Bool {
        #if canImport(UIKit)
        return image != nil
        #else
        return false
        #endif
    }

    private var filename: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if findOpen {
                findBar
            }
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

    @ViewBuilder
    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
            TextField("Find", text: $findQuery)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($findFocused)
                .submitLabel(.search)
                .onSubmit { jumpToMatch(findIndex) } // re-anchor on Enter
                .onChange(of: findQuery) { _, _ in
                    findIndex = 0
                    if !findMatches.isEmpty { jumpToMatch(0) }
                }
            Text(_matchCounter)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textQuaternary)
                .frame(minWidth: 44)
            Button {
                advanceMatch(by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(findMatches.isEmpty)
            .foregroundStyle(theme.textSecondary)
            Button {
                advanceMatch(by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(findMatches.isEmpty)
            .foregroundStyle(theme.textSecondary)
            Button { closeFind() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.textQuaternary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
    }

    private var _matchCounter: String {
        guard !findQuery.isEmpty else { return "" }
        if findMatches.isEmpty { return "0/0" }
        return "\(findIndex + 1)/\(findMatches.count)"
    }

    private func openFind() {
        guard !isBinary, !isImageMode else { return }
        findOpen = true
        DispatchQueue.main.async { findFocused = true }
    }

    private func closeFind() {
        findOpen = false
        findQuery = ""
        findFocused = false
    }

    private func advanceMatch(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        let n = findMatches.count
        let ni = (findIndex + delta + n) % n
        findIndex = ni
        jumpToMatch(ni)
    }

    private func jumpToMatch(_ idx: Int) {
        guard idx >= 0, idx < findMatches.count else { return }
        selectedRange = findMatches[idx]
        scrollTarget &+= 1
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
            if !isBinary && !loading && !isImageMode {
                Button { openFind() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                }
                .foregroundStyle(theme.textSecondary)
                .help("Find (⌘F)")
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
                .help(saving ? "Saving…" : "Save")
            }
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15))
            }
            .disabled(loading)
            .foregroundStyle(theme.textSecondary)
            .help("Reload from disk")
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
        } else if isBinary {
            Text("Binary file — download it from the file browser.")
                .font(theme.bodyFont(size: 13))
                .foregroundStyle(theme.textQuaternary)
                .italic()
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if savedContent != nil {
            #if canImport(UIKit)
            SelectableTextEditor(
                text: $draft,
                selectedRange: $selectedRange,
                scrollTarget: scrollTarget,
                shouldFocus: !findOpen,
                highlightRange: currentFindMatch,
            )
            .background(theme.elevated)
            #else
            TextEditor(text: $draft)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(theme.elevated)
                .padding(.horizontal, 6)
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
        #endif
        defer { loading = false }
        do {
            let (data, response) = try await relay.apiClient.readFile(
                kind, id: targetId, path: path, server: server,
            )
            let ct = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isText = ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") || _hasTextExt(path)
            let isImage = ct.hasPrefix("image/") || (!isText && _hasImageExt(path))
            if isText {
                let text = String(data: data, encoding: .utf8) ?? ""
                savedContent = text
                draft = text
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
            } else {
                isBinary = true
                savedContent = nil
            }
            notOnDisk = false
        } catch APIClient.APIError.httpError(404) {
            // Treat the tab as a "new file" — empty saved state, draft
            // preserved (so a delete-while-editing keeps the user's work).
            // Save will recreate the file on disk.
            savedContent = ""
            isBinary = false
            notOnDisk = true
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
            try await relay.apiClient.writeFile(
                kind, id: targetId, path: path,
                body: draft.data(using: .utf8) ?? Data(), server: server,
            )
            savedContent = draft
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
            return
        }
        if isDirty {
            staleBanner = true
        } else {
            Task { await loadFile() }
        }
    }
}

private func _hasTextExt(_ path: String) -> Bool {
    let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
    return [
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "ini", "cfg",
        "csv", "tsv", "log", "py", "js", "ts", "tsx", "jsx", "swift", "go",
        "rs", "rb", "java", "c", "h", "cpp", "hpp", "cs", "sh", "bash", "zsh",
        "css", "scss", "html", "xml", "sql", "env", "gitignore",
    ].contains(ext)
}

private func _hasImageExt(_ path: String) -> Bool {
    let ext = path.split(separator: ".").last.map { String($0).lowercased() } ?? ""
    return [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff",
        "heic", "heif", "ico",
    ].contains(ext)
}
