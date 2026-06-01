import SwiftUI

/// Quick create-a-session sheet launched from the agent's long-press
/// context menu. Lets the user pick a project (or "No project") and
/// jump straight into the new session — short-circuits the
/// lobby + operator round-trip that was the only path before.
struct CreateChatSheet: View {
    let relay: RelayViewModel
    let agent: Agent
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme

    @State private var selectedProjectId: String = "" // "" = No project
    @State private var name: String = ""
    @State private var busy = false
    @State private var error: String?

    /// Projects are partitioned by ark backend (different arks can't share
    /// project_ids). Only show ones on the same backend as this agent.
    private var compatibleProjects: [Project] {
        let target = (agent.llmBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relay.projects.filter { $0.serverId == target }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    Text(agent.name)
                        .font(theme.bodyFont(size: 16, weight: .medium))
                }
                Section {
                    TextField("(auto-named after a couple of turns)", text: $name)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Name (optional)")
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
                    if compatibleProjects.isEmpty {
                        Text("No projects on this agent's ark backend yet.")
                            .font(.caption2)
                    }
                }
                if let err = error {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface)
            .navigationTitle("Create chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await submit() }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        let chosen = compatibleProjects.first(where: { $0.id == selectedProjectId })
        do {
            let session = try await relay.apiClient.createSession(
                agentId: agent.agentId,
                projectId: chosen?.id,
                projectServerId: chosen?.serverId,
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name,
            )
            onCreated(session.sessionId)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
