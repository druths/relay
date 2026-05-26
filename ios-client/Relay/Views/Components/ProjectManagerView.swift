import SwiftUI

/// Manage ark projects: list grouped by ark server, create, edit, soft-delete.
/// Mirrors the web `ProjectManager` modal — same behavior, sheet-style for iOS.
struct ProjectManagerView: View {
    let relay: RelayViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme

    @State private var selected: Project?
    @State private var creating = false
    @State private var servers: [ArkServerInfo] = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if creating {
                    NewProjectForm(
                        servers: servers,
                        onCreated: { p in
                            creating = false
                            selected = p
                            Task { await relay.fetchProjects() }
                        },
                        onCancel: { creating = false },
                        relay: relay,
                    )
                } else if let p = selected {
                    ProjectDetailForm(
                        project: p,
                        onChanged: { Task { await relay.fetchProjects() } },
                        onDeleted: {
                            selected = nil
                            Task { await relay.fetchProjects() }
                        },
                        relay: relay,
                    )
                    .id(p.id)
                } else {
                    projectList
                }
            }
            .background(theme.surface)
            .navigationTitle(
                creating ? "New Project"
                : selected?.name ?? "Projects"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if creating || selected != nil {
                        Button("Back") {
                            creating = false
                            selected = nil
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                if !creating && selected == nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { creating = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .task {
            do {
                servers = try await relay.apiClient.listArkServers()
            } catch {
                servers = []
            }
            await relay.fetchProjects()
        }
    }

    // ── list ─────────────────────────────────────────────────────────

    private var projectList: some View {
        let grouped = Dictionary(grouping: relay.projects, by: { $0.serverId })
        let sortedServers = grouped.keys.sorted()
        let multiServer = sortedServers.count > 1

        return List {
            if relay.projects.isEmpty {
                Text("No projects yet.")
                    .font(theme.bodyFont(size: 14))
                    .foregroundStyle(theme.textQuaternary)
            }
            ForEach(sortedServers, id: \.self) { sid in
                Section {
                    ForEach(grouped[sid] ?? []) { p in
                        Button {
                            selected = p
                        } label: {
                            HStack {
                                Text(p.name)
                                    .font(theme.bodyFont(size: 16))
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(theme.textQuaternary)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } header: {
                    if multiServer {
                        Text(_shortServer(sid))
                            .font(theme.bodyFont(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            if let err = errorText {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.surface)
    }
}

// MARK: - Detail form

private struct ProjectDetailForm: View {
    let project: Project
    let onChanged: () -> Void
    let onDeleted: () -> Void
    let relay: RelayViewModel

    @Environment(\.relayTheme) private var theme

    @State private var name: String
    @State private var description: String
    @State private var context: String
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var error: String?

    init(project: Project, onChanged: @escaping () -> Void, onDeleted: @escaping () -> Void, relay: RelayViewModel) {
        self.project = project
        self.onChanged = onChanged
        self.onDeleted = onDeleted
        self.relay = relay
        _name = State(initialValue: project.name)
        _description = State(initialValue: project.description ?? "")
        _context = State(initialValue: project.projectContext ?? "")
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Project name", text: $name)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await save(field: "name") } }
            }
            Section("Description") {
                TextField("(optional)", text: $description, axis: .vertical)
                    .lineLimit(1...3)
                    .onSubmit { Task { await save(field: "description") } }
            }
            Section("Project context") {
                TextEditor(text: $context)
                    .frame(minHeight: 120)
                    .font(.system(size: 13, design: .monospaced))
            }

            Section {
                Button {
                    Task {
                        await save(field: "all")
                    }
                } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(saving)
            }

            Section {
                if let root = project.root {
                    LabeledContent("Root") {
                        Text(root).font(.system(size: 12, design: .monospaced))
                    }
                }
                LabeledContent("Project ID") {
                    Text(project.id).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("ark server") {
                    Text(project.serverId).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let err = error {
                Section { Text(err).foregroundStyle(.red) }
            }

            Section {
                if confirmDelete {
                    HStack {
                        Text("Soft-delete this project?")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Confirm") { Task { await doDelete() } }
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                        Button("Cancel") { confirmDelete = false }
                    }
                } else {
                    Button("Soft-delete project", role: .destructive) {
                        confirmDelete = true
                    }
                }
            } footer: {
                Text("Files survive on disk; sessions retain their binding but lose project context at runtime.")
                    .font(.caption2)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.surface)
    }

    private func save(field: String) async {
        saving = true
        error = nil
        defer { saving = false }
        let api = relay.apiClient
        do {
            switch field {
            case "name":
                _ = try await api.updateProject(projectId: project.id, server: project.serverId, name: name)
            case "description":
                _ = try await api.updateProject(projectId: project.id, server: project.serverId, description: description)
            default:
                _ = try await api.updateProject(
                    projectId: project.id, server: project.serverId,
                    name: name != project.name ? name : nil,
                    description: description != (project.description ?? "") ? description : nil,
                    projectContext: context != (project.projectContext ?? "") ? context : nil,
                )
            }
            onChanged()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func doDelete() async {
        let api = relay.apiClient
        do {
            try await api.deleteProject(projectId: project.id, server: project.serverId)
            onDeleted()
        } catch {
            self.error = String(describing: error)
            confirmDelete = false
        }
    }
}

// MARK: - New project form

private struct NewProjectForm: View {
    let servers: [ArkServerInfo]
    let onCreated: (Project) -> Void
    let onCancel: () -> Void
    let relay: RelayViewModel

    @Environment(\.relayTheme) private var theme

    @State private var name = ""
    @State private var description = ""
    @State private var context = ""
    @State private var server: String = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. marketing-brochure", text: $name)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }
            Section("Description") {
                TextField("(optional)", text: $description)
            }
            Section {
                TextEditor(text: $context)
                    .frame(minHeight: 120)
                    .font(.system(size: 13, design: .monospaced))
            } header: {
                Text("Project context")
            } footer: {
                Text("Injected into the system prompt of every agent in this project.")
                    .font(.caption2)
            }
            if servers.count > 1 {
                Section("ark server") {
                    Picker("Server", selection: $server) {
                        ForEach(servers, id: \.serverId) { s in
                            Text(_shortServer(s.serverId)).tag(s.serverId)
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if busy { ProgressView() } else { Text("Create") }
                }
                .disabled(busy || name.isEmpty || resolvedServer.isEmpty)
            }
            if let err = error {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.surface)
        .onAppear {
            if server.isEmpty, let first = servers.first?.serverId { server = first }
        }
    }

    private var resolvedServer: String {
        if !server.isEmpty { return server }
        return servers.first?.serverId ?? ""
    }

    private func submit() async {
        let target = resolvedServer
        guard !target.isEmpty else {
            error = "No ark backend is configured."
            return
        }
        busy = true
        defer { busy = false }
        let api = relay.apiClient
        do {
            let p = try await api.createProject(
                server: target, name: name,
                description: description.isEmpty ? nil : description,
                projectContext: context.isEmpty ? nil : context,
            )
            onCreated(p)
        } catch {
            self.error = String(describing: error)
        }
    }
}

// MARK: - helpers

private func _shortServer(_ s: String) -> String {
    if let r = s.range(of: "://") { return String(s[r.upperBound...]) }
    return s
}
