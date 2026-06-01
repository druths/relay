import SwiftUI
import UniformTypeIdentifiers

/// Tabbed file browser for the active session: Project (if bound) +
/// Workspace (for ark agents). Mirrors the web `FileBrowserPanel` —
/// expandable tree, upload/mkdir/refresh icons, click-to-view, inline
/// text edit with Save/Cancel, "Recent changes" feed.
struct FileBrowserView: View {
    let relay: RelayViewModel
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme

    @State private var selectedTab: Kind

    enum Kind: Hashable { case project, workspace }

    init(relay: RelayViewModel, session: Session) {
        self.relay = relay
        self.session = session
        // Default to Project when bound; otherwise Workspace.
        _selectedTab = State(initialValue: session.projectId != nil ? .project : .workspace)
    }

    private var projectAvailable: Bool { session.projectId != nil }
    private var workspaceAvailable: Bool {
        // Workspaces only exist for ark agents.
        relay.agents.first(where: { $0.agentId == session.agentId })?.llmProvider == "ark"
    }

    /// ark's `agent_name` in `workspace_file_changed` events is the agent's
    /// `llm_model` (minus any `ark:` prefix), which can differ in case from
    /// Relay's display name. Use this for scope matching; the tab label
    /// keeps the display name.
    private var workspaceArkName: String {
        guard let agent = relay.agents.first(where: { $0.agentId == session.agentId }) else {
            return session.agentName
        }
        let model = agent.llmModel
        if model.hasPrefix("ark:") {
            return String(model.dropFirst("ark:".count))
        }
        return model.isEmpty ? session.agentName : model
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                if selectedTab == .project, let pid = session.projectId {
                    FileTreeView(
                        relay: relay,
                        kind: .project,
                        targetId: pid,
                        scope: pid,
                        server: session.projectServerId,
                    )
                } else if selectedTab == .workspace, workspaceAvailable {
                    FileTreeView(
                        relay: relay,
                        kind: .workspace,
                        targetId: session.agentId,
                        scope: workspaceArkName,
                        server: nil,
                    )
                } else {
                    Spacer()
                    Text("No filesystem to show here.")
                        .font(theme.bodyFont(size: 14))
                        .foregroundStyle(theme.textQuaternary)
                    Spacer()
                }
            }
            .background(theme.surface)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 0) {
            if projectAvailable {
                tabButton(
                    label: "Project" + (projectName.map { " · \($0)" } ?? ""),
                    active: selectedTab == .project,
                ) { selectedTab = .project }
            }
            if workspaceAvailable {
                tabButton(
                    label: "Workspace · \(session.agentName)",
                    active: selectedTab == .workspace,
                ) { selectedTab = .workspace }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
    }

    private func tabButton(label: String, active: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(theme.bodyFont(size: 13))
                .lineLimit(1)
                .foregroundStyle(active ? theme.textPrimary : theme.textQuaternary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    if active {
                        Rectangle().fill(theme.primary).frame(height: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var projectName: String? {
        guard let pid = session.projectId else { return nil }
        return relay.projects.first(where: { $0.id == pid })?.name
    }
}

// MARK: - Tree view

private struct FileTreeView: View {
    let relay: RelayViewModel
    let kind: APIClient.FsKind
    let targetId: String
    let scope: String
    let server: String?

    @Environment(\.relayTheme) private var theme

    @State private var rootListing: DirListing?
    @State private var expanded: [String: DirListing] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var selectedPath: String?
    @State private var uploading = false
    @State private var showFilePicker = false
    @State private var showMkdirAlert = false
    @State private var mkdirName = ""
    @State private var pathToDelete: String?
    @State private var lastSeenFileChangeTs: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let err = error {
                Text(err)
                    .font(theme.monoFont(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let root = rootListing {
                        DirEntries(
                            listing: root,
                            path: "",
                            depth: 0,
                            expanded: $expanded,
                            selectedPath: $selectedPath,
                            onExpand: load,
                            onDelete: { pathToDelete = $0 },
                        )
                    } else if loading {
                        ProgressView().padding()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            if let path = selectedPath {
                FilePreviewSheet(
                    relay: relay,
                    kind: kind,
                    targetId: targetId,
                    path: path,
                    server: server,
                    onClose: { selectedPath = nil },
                )
                .frame(minHeight: 200, idealHeight: 260, maxHeight: 480)
            }

            // Recent changes feed.
            let recent = relay.fileChanges
                .filter { ev in
                    ev.kind.rawValue == (kind == .project ? "project" : "workspace")
                    && ev.scope == scope
                }
                .suffix(8)
                .reversed()
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT CHANGES")
                        .font(theme.labelFont(size: 10))
                        .tracking(1)
                        .foregroundStyle(theme.textQuaternary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                    ForEach(Array(recent), id: \.id) { ev in
                        HStack {
                            Text(ev.change.rawValue.prefix(1).uppercased())
                                .font(theme.monoFont(size: 11, weight: .bold))
                                .foregroundStyle(_changeColor(ev.change))
                                .frame(width: 12)
                            Text(ev.path)
                                .font(theme.monoFont(size: 11))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                            Spacer()
                            Text(_relativeTime(ev.ts))
                                .font(theme.monoFont(size: 10))
                                .foregroundStyle(theme.textQuaternary)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 6)
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.border).frame(height: theme.borderWidth)
                }
            }
        }
        .task(id: "\(kind)-\(targetId)") {
            await loadRoot()
        }
        .onChange(of: relay.fileChanges.count) { _, _ in
            handleFileChanges()
        }
        .alert("New folder", isPresented: $showMkdirAlert) {
            TextField("Folder name", text: $mkdirName)
            Button("Create") { Task { await doMkdir() } }
            Button("Cancel", role: .cancel) { mkdirName = "" }
        }
        .alert("Delete?", isPresented: Binding(
            get: { pathToDelete != nil },
            set: { if !$0 { pathToDelete = nil } },
        )) {
            Button("Delete", role: .destructive) {
                if let p = pathToDelete { Task { await doDelete(p) } }
            }
            Button("Cancel", role: .cancel) { pathToDelete = nil }
        } message: {
            Text(pathToDelete.map { "Delete \($0)?" } ?? "")
        }
        .fileImporter(
            isPresented: $showFilePicker, allowedContentTypes: [.data], allowsMultipleSelection: true,
        ) { result in
            switch result {
            case .success(let urls): Task { await uploadFiles(urls) }
            case .failure(let err): self.error = String(describing: err)
            }
        }
    }

    // ── Toolbar ──────────────────────────────────────────────────────

    private var toolbar: some View {
        HStack(spacing: 0) {
            ToolbarIconButton(
                system: uploading ? "circle.dotted" : "arrow.up.doc",
                title: uploading ? "Uploading…" : "Upload",
                disabled: uploading,
            ) { showFilePicker = true }
            ToolbarIconButton(system: "folder.badge.plus", title: "New folder") {
                showMkdirAlert = true
            }
            ToolbarIconButton(system: "arrow.clockwise", title: "Refresh") {
                Task { await loadRoot() }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
    }

    // ── Loading + mutating ───────────────────────────────────────────

    private func loadRoot() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            rootListing = try await relay.apiClient.listDir(kind, id: targetId, path: "", server: server)
            expanded = [:]
        } catch {
            self.error = String(describing: error)
        }
    }

    private func load(path: String) {
        Task {
            do {
                let listing = try await relay.apiClient.listDir(kind, id: targetId, path: path, server: server)
                expanded[path] = listing
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    private func uploadFiles(_ urls: [URL]) async {
        uploading = true
        defer { uploading = false }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                try await relay.apiClient.writeFile(
                    kind, id: targetId, path: url.lastPathComponent, body: data, server: server,
                )
            } catch {
                self.error = String(describing: error)
            }
        }
        await loadRoot()
    }

    private func doMkdir() async {
        let name = mkdirName.trimmingCharacters(in: .whitespaces)
        mkdirName = ""
        guard !name.isEmpty else { return }
        do {
            try await relay.apiClient.mkdir(kind, id: targetId, path: name, server: server)
            await loadRoot()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func doDelete(_ path: String) async {
        do {
            try await relay.apiClient.deleteFile(kind, id: targetId, path: path, server: server)
            pathToDelete = nil
            // Refresh the parent listing.
            let parent = path.contains("/") ? String(path[..<(path.lastIndex(of: "/") ?? path.endIndex)]) : ""
            if parent.isEmpty { await loadRoot() } else { load(path: parent) }
            if selectedPath == path { selectedPath = nil }
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Refresh the deepest open ancestor of every newly-arrived file-change
    /// event for our scope. Closed subdirs are left alone (they'll reload
    /// next time the user expands them).
    private func handleFileChanges() {
        let mine = relay.fileChanges.filter { ev in
            ev.ts > lastSeenFileChangeTs
            && ev.kind.rawValue == (kind == .project ? "project" : "workspace")
            && ev.scope == scope
        }
        if mine.isEmpty { return }
        lastSeenFileChangeTs = mine.map(\.ts).max() ?? lastSeenFileChangeTs
        var touched: Set<String> = []
        for ev in mine {
            let parent = ev.path.contains("/") ? String(ev.path[..<(ev.path.lastIndex(of: "/") ?? ev.path.endIndex)]) : ""
            touched.insert(parent)
        }
        for dir in touched {
            if dir.isEmpty { Task { await loadRoot() } }
            else if expanded[dir] != nil { load(path: dir) }
        }
    }
}

// MARK: - Directory entries (recursive)

private struct DirEntries: View {
    let listing: DirListing
    let path: String
    let depth: Int
    @Binding var expanded: [String: DirListing]
    @Binding var selectedPath: String?
    let onExpand: (String) -> Void
    let onDelete: (String) -> Void

    @Environment(\.relayTheme) private var theme

    var body: some View {
        ForEach(listing.entries) { entry in
            let childPath = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
            let isOpen = expanded[childPath] != nil
            HStack(spacing: 4) {
                Text(entry.isDir ? (isOpen ? "▾" : "▸") : " ")
                    .font(theme.monoFont(size: 13))
                    .foregroundStyle(theme.textQuaternary)
                    .frame(width: 10)
                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                Text(entry.name)
                    .font(theme.bodyFont(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if !entry.isDir {
                    Text(_formatSize(entry.size))
                        .font(theme.monoFont(size: 11))
                        .foregroundStyle(theme.textQuaternary)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.horizontal, 6)
            .background(
                selectedPath == childPath ? theme.elevated : Color.clear,
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture {
                if entry.isDir {
                    if isOpen { expanded.removeValue(forKey: childPath) }
                    else { onExpand(childPath) }
                } else {
                    selectedPath = childPath
                }
            }
            .contextMenu {
                Button(role: .destructive) { onDelete(childPath) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            if let sub = expanded[childPath] {
                DirEntries(
                    listing: sub,
                    path: childPath,
                    depth: depth + 1,
                    expanded: $expanded,
                    selectedPath: $selectedPath,
                    onExpand: onExpand,
                    onDelete: onDelete,
                )
            }
        }
    }
}

// MARK: - File preview / editor

private struct FilePreviewSheet: View {
    let relay: RelayViewModel
    let kind: APIClient.FsKind
    let targetId: String
    let path: String
    let server: String?
    let onClose: () -> Void

    @Environment(\.relayTheme) private var theme

    @State private var content: String?
    @State private var binary = false
    @State private var loading = true
    @State private var error: String?
    @State private var editing = false
    @State private var draft: String = ""
    @State private var saving = false

    private var filename: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if loading {
                    HStack { ProgressView(); Spacer() }
                        .padding()
                } else if let err = error {
                    Text(err).font(theme.monoFont(size: 12)).foregroundStyle(.red).padding()
                } else if binary {
                    Text("Binary file — use Download to save locally.")
                        .font(theme.bodyFont(size: 12))
                        .foregroundStyle(theme.textQuaternary)
                        .italic()
                        .padding()
                } else if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(theme.surface)
                        .padding(.horizontal, 6)
                } else if let text = content {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(theme.elevated)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
        .task(id: path) { await loadFile() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(path)
                .font(theme.monoFont(size: 11))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
            Spacer()
            if editing {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await save() } } label: {
                        Image(systemName: "checkmark").imageScale(.small)
                    }
                    .foregroundStyle(theme.success)
                }
                Button { editing = false; draft = "" } label: {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .foregroundStyle(theme.textQuaternary)
            } else {
                if !binary && content != nil && !loading {
                    Button { startEdit() } label: {
                        Image(systemName: "pencil").imageScale(.small)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
                Button { Task { await download() } } label: {
                    Image(systemName: "arrow.down.doc").imageScale(.small)
                }
                .foregroundStyle(theme.primary)
                Button(action: onClose) {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .foregroundStyle(theme.textQuaternary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surface)
    }

    private func loadFile() async {
        loading = true
        error = nil
        binary = false
        content = nil
        editing = false
        defer { loading = false }
        do {
            let (data, response) = try await relay.apiClient.readFile(
                kind, id: targetId, path: path, server: server,
            )
            let ct = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            if ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") || _hasTextExt(path) {
                content = String(data: data, encoding: .utf8) ?? "(non-UTF8 text)"
            } else {
                binary = true
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    private func startEdit() {
        draft = content ?? ""
        editing = true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await relay.apiClient.writeFile(
                kind, id: targetId, path: path,
                body: draft.data(using: .utf8) ?? Data(), server: server,
            )
            content = draft
            editing = false
        } catch {
            self.error = String(describing: error)
        }
    }

    private func download() async {
        do {
            let (data, _) = try await relay.apiClient.readFile(
                kind, id: targetId, path: path, server: server,
            )
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let fileURL = tmp.appendingPathComponent(filename)
            try data.write(to: fileURL)
            // Hand off to system share sheet.
            await MainActor.run { _presentShareSheet(url: fileURL) }
        } catch {
            self.error = String(describing: error)
        }
    }
}

// MARK: - Toolbar icon

private struct ToolbarIconButton: View {
    let system: String
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    @Environment(\.relayTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17))
                .foregroundStyle(disabled ? theme.textQuaternary : theme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .disabled(disabled)
        .help(title)
    }
}

// MARK: - helpers

private func _formatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    if bytes < 1024 * 1024 { return String(format: "%.1fK", Double(bytes) / 1024) }
    return String(format: "%.1fM", Double(bytes) / 1024 / 1024)
}

private func _relativeTime(_ ts: Date) -> String {
    let secs = Int(Date().timeIntervalSince(ts))
    if secs < 60 { return "\(secs)s" }
    if secs < 3600 { return "\(secs / 60)m" }
    if secs < 86400 { return "\(secs / 3600)h" }
    return "\(secs / 86400)d"
}

private func _changeColor(_ change: FileChangeEvent.Change) -> Color {
    switch change {
    case .created: .green
    case .deleted: .red
    case .modified: .orange
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

#if canImport(UIKit)
import UIKit

private func _presentShareSheet(url: URL) {
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?
        .rootViewController?
        .present(sheet, animated: true)
}
#else
private func _presentShareSheet(url: URL) {}
#endif
