import Combine
import SwiftUI

struct RelayView: View {
    let authService: AuthService

    @State private var relay: RelayViewModel
    @State private var showSettings = false
    @State private var showMenu = false

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
        .fullScreenCover(isPresented: $showMenu) {
            menuSheet
        }
        .task { await relay.connect() }
        .onDisappear { Task { await relay.disconnect() } }
        .onReceive(NotificationCenter.default.publisher(for: .relayToggleMute)) { _ in
            relay.toggleMute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayExitLive)) { _ in
            relay.exitLiveMode()
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

            VStack(alignment: .leading, spacing: 1) {
                Text("Relay")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.relayTextPrimary)

                Text(relay.activeSessionId != nil
                     ? (relay.activeAgentName ?? "Session")
                     : "Lobby")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextTertiary)
            }

            Spacer()

            if relay.activeSessionId != nil {
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
        .padding(.vertical, 6)
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
                    Section("Recent Sessions") {
                        ForEach(relay.sessions.prefix(10)) { session in
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
}
