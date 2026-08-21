import SwiftUI

/// Reassign / detach a session's ark project binding. Invoked from the
/// session-list context menu ("Set Project…"). Shows a single Picker
/// with `No project` at the top and every compatible project below;
/// Save is disabled until the selection differs from what's already on
/// the session, so a stray tap doesn't generate a no-op PATCH.
///
/// Projects are filtered to the ark server the session's currently
/// bound to (multi-ark setups reject cross-server binds with 404). If
/// the session has never been assigned a project — `projectServerId`
/// nil — we fall back to matching the session's agent's ark backend,
/// which is where any subsequent assignment must live anyway.
struct SetProjectSheet: View {
    let relay: RelayViewModel
    let session: Session

    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme

    @State private var selectedProjectId: String
    @State private var busy = false
    @State private var error: String?

    init(relay: RelayViewModel, session: Session) {
        self.relay = relay
        self.session = session
        _selectedProjectId = State(initialValue: session.projectId ?? "")
    }

    /// Ark backend this session's agent talks to. `Project.serverId` is
    /// the normalized base URL (see `_server_id_for` in ark.py), so we
    /// canonicalize the agent's `llmBaseUrl` the same way and match on
    /// equality. Ark rejects cross-server binds with 404, so filtering
    /// on the agent is exactly the right constraint regardless of what
    /// project (if any) the session currently holds.
    private var targetServer: String? {
        guard let agent = relay.agents.first(where: { $0.agentId == session.agentId }) else {
            return nil
        }
        return (agent.llmBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var compatibleProjects: [Project] {
        guard let target = targetServer, !target.isEmpty else { return [] }
        return relay.projects.filter { $0.serverId == target }
    }

    private var dirty: Bool {
        let current = session.projectId ?? ""
        return selectedProjectId != current
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    Text(session.name ?? session.agentName)
                        .font(theme.bodyFont(size: 16, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                }
                Section {
                    Picker("Project", selection: $selectedProjectId) {
                        Text("No project").tag("")
                        ForEach(compatibleProjects) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                } header: {
                    Text("Project")
                } footer: {
                    Text(
                        "Choosing 'No project' detaches this session. The " +
                        "agent will be notified on the next turn — references " +
                        "to old project files will no longer resolve."
                    )
                    .font(.caption2)
                }
                if let err = error {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface)
            .navigationTitle("Set project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!dirty)
                    }
                }
            }
        }
    }

    private func save() async {
        busy = true
        error = nil
        do {
            let projectId: String? = selectedProjectId.isEmpty ? nil : selectedProjectId
            try await relay.setSessionProject(session.sessionId, projectId: projectId)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
        busy = false
    }
}
