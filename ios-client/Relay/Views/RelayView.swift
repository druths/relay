import Combine
import SwiftUI

struct RelayView: View {
    let authService: AuthService

    @Environment(\.scenePhase) private var scenePhase
    @State private var relay: RelayViewModel
    @State private var showSettings = false
    @State private var showMenu = false
    @State private var showRenameAlert = false
    @State private var renameSessionId: String?
    @State private var renameText = ""
    @State private var showLabelEditor = false
    @State private var labelInputText = ""
    @State private var menuLabelFilter: String?

    init(authService: AuthService) {
        self.authService = authService
        _relay = State(initialValue: RelayViewModel(authService: authService))
    }

    private var currentMessages: [Message] {
        relay.activeSessionId != nil ? relay.sessionMessages : relay.lobbyMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Agent cards — only when in lobby
            if relay.connected && relay.activeSessionId == nil {
                AgentSelector(
                    agents: relay.agents,
                    activeAgentName: relay.activeAgentName,
                    onSelect: { agent in
                        Task { await relay.sendMessage("connect me to \(agent.name)") }
                    }
                )
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.relayBorder).frame(height: 1)
                }
            }

            // Session labels bar — when in session with labels
            if relay.activeSessionId != nil && !relay.activeSessionLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(relay.activeSessionLabels, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.relayPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.relayPrimary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.relayBorder).frame(height: 1)
                }
            }

            ConversationLog(
                messages: currentMessages,
                activeSessionId: relay.activeSessionId,
                activeAgentName: relay.activeAgentName,
                connected: relay.connected
            )
            .frame(maxHeight: .infinity)

            InputBar(relay: relay)
        }
        .background(Color.relaySurface)
        .fullScreenCover(isPresented: $showSettings) {
            AgentManagementView(
                agents: relay.agents,
                authService: authService,
                onChanged: { Task { await relay.refreshAgents() } }
            )
        }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing { Task { await relay.fetchPlatformSettings() } }
        }
        .fullScreenCover(isPresented: $showMenu) {
            menuSheet
        }
        .sheet(isPresented: $showLabelEditor) {
            labelEditorSheet
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Session name", text: $renameText)
            Button("Save") {
                if let sessionId = renameSessionId, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Task { await relay.renameSession(sessionId, name: renameText.trimmingCharacters(in: .whitespaces)) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await relay.connect() }
        .onDisappear { Task { await relay.disconnect() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !relay.connected {
                Task { await relay.reconnect() }
            }
        }
        .onChange(of: relay.connected) { _, isConnected in
            if !isConnected && scenePhase == .active {
                Task { await relay.reconnect() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayToggleMute)) { _ in
            relay.toggleMute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayExitLive)) { _ in
            relay.exitLiveMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayEnterLive)) { _ in
            if !relay.connected {
                Task {
                    await relay.connect()
                    relay.enterLiveMode()
                }
            } else if !relay.isLiveMode {
                relay.enterLiveMode()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { showMenu = true }) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.relayTextTertiary)
            }

            StatusOrb(
                activeSpeaker: relay.activeSpeaker,
                status: relay.status,
                connected: relay.connected,
                compact: true
            )

            Text(relay.activeAgentName ?? "Operator")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.relayTextPrimary)

            Spacer()

            if relay.activeSessionId != nil {
                // Session kebab menu
                Menu {
                    Button {
                        renameSessionId = relay.activeSessionId
                        renameText = relay.sessions.first(where: { $0.sessionId == relay.activeSessionId })?.name ?? ""
                        showRenameAlert = true
                    } label: {
                        Label("Rename Session", systemImage: "pencil")
                    }

                    Button {
                        showLabelEditor = true
                    } label: {
                        Label("Manage Labels", systemImage: "tag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.relayTextTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }

                Button(action: { Task { await relay.leaveSession() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Lobby")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.relayWarning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.relayWarning.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.relaySurface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.relayBorder).frame(height: 1)
        }
    }

    // MARK: - Menu Sheet

    private var menuSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: {
                        showMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showSettings = true
                        }
                    }) {
                        Label("Settings", systemImage: "gearshape")
                    }

                    Button(role: .destructive, action: {
                        showMenu = false
                        authService.logout()
                    }) {
                        Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                if !relay.sessions.isEmpty {
                    // Label filter chips
                    let allLabels = Array(Set(relay.sessions.flatMap(\.labels))).sorted()
                    if !allLabels.isEmpty {
                        Section("Labels") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(allLabels, id: \.self) { label in
                                        Button {
                                            menuLabelFilter = menuLabelFilter == label ? nil : label
                                        } label: {
                                            Text(label)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(menuLabelFilter == label ? .white : Color.relayPrimary)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(menuLabelFilter == label ? Color.relayPrimary : Color.relayPrimary.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }

                    let filteredSessions = menuLabelFilter.map { filter in
                        relay.sessions.filter { $0.labels.contains(filter) }
                    } ?? Array(relay.sessions.prefix(10))

                    Section(menuLabelFilter.map { "Sessions: \($0)" } ?? "Recent Sessions") {
                        ForEach(filteredSessions.prefix(10)) { session in
                            Button(action: {
                                showMenu = false
                                Task { await relay.resumeSession(session.sessionId) }
                            }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.name ?? session.agentName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.relayTextSecondary)
                                        .lineLimit(1)

                                    HStack(spacing: 4) {
                                        Text(session.agentName)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.relayTextQuaternary)

                                        Text("·")
                                            .foregroundStyle(Color.relayTextQuaternary)

                                        Text(session.status)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.relayTextQuaternary)
                                    }

                                    if !session.labels.isEmpty {
                                        HStack(spacing: 4) {
                                            ForEach(session.labels, id: \.self) { label in
                                                Text(label)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(Color.relayPrimary)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(Color.relayPrimary.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }

                                    if let summary = session.summary {
                                        Text(summary)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.relayTextTertiary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await relay.deleteSession(session.sessionId) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    renameSessionId = session.sessionId
                                    renameText = session.name ?? ""
                                    showMenu = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showRenameAlert = true
                                    }
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showMenu = false }
                }
            }
        }
        .background(Color.relaySurface)
    }

    // MARK: - Label Editor Sheet

    private var labelEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if relay.activeSessionLabels.isEmpty {
                    Text("No labels yet")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.relayTextTertiary)
                        .padding(.horizontal, 16)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(relay.activeSessionLabels, id: \.self) { label in
                                HStack(spacing: 4) {
                                    Text(label)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.relayPrimary)

                                    Button {
                                        guard let sessionId = relay.activeSessionId else { return }
                                        let newLabels = relay.activeSessionLabels.filter { $0 != label }
                                        Task { await relay.updateSessionLabels(sessionId, labels: newLabels) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.relayPrimary.opacity(0.6))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.relayPrimary.opacity(0.15))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Add a label...", text: $labelInputText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addLabel()
                        }

                    Button("Add") {
                        addLabel()
                    }
                    .disabled(labelInputText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)

                // Existing labels as quick-add suggestions
                let existingLabels = Array(Set(relay.sessions.flatMap(\.labels)))
                    .sorted()
                    .filter { !relay.activeSessionLabels.contains($0) }
                if !existingLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Existing Labels")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.relayTextQuaternary)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(existingLabels, id: \.self) { label in
                                    Button {
                                        guard let sessionId = relay.activeSessionId else { return }
                                        let newLabels = relay.activeSessionLabels + [label]
                                        Task { await relay.updateSessionLabels(sessionId, labels: newLabels) }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 12))
                                            Text(label)
                                                .font(.system(size: 13, weight: .medium))
                                        }
                                        .foregroundStyle(Color.relayTextTertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.relayElevated)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("Manage Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showLabelEditor = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func addLabel() {
        let trimmed = labelInputText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let sessionId = relay.activeSessionId else { return }
        let newLabels = relay.activeSessionLabels + [trimmed]
        Task { await relay.updateSessionLabels(sessionId, labels: newLabels) }
        labelInputText = ""
    }
}
