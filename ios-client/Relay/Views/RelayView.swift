import Combine
import SwiftUI

struct RelayView: View {
    let authService: AuthService
    let themeManager: ThemeManager

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.relayTheme) private var theme
    @State private var relay: RelayViewModel
    @State private var showSettings = false
    @State private var showMenu = false
    @State private var showActivityLog = false
    @State private var showRenameAlert = false
    /// When set, present a confirm alert before closing the named tab —
    /// it has unsaved edits and we don't want to silently drop them.
    @State private var pendingCloseTabId: String? = nil
    @State private var renameSessionId: String?
    @State private var renameText = ""
    @State private var showLabelEditor = false
    @State private var labelInputText = ""
    @State private var menuLabelFilter: String?
    @State private var sidebarLabelFilter: String?
    @State private var sidebarSessionSearch = ""
    @State private var sidebarSearchQuery = ""
    @State private var menuSessionSearch = ""
    @State private var menuSearchQuery = ""
    @FocusState private var sidebarSearchFocused: Bool
    /// Global Diagnostics preference: when on, every bubble shows its
    /// timestamp and agent bubbles show context-window / token usage when the
    /// underlying message has metadata attached.
    @AppStorage("relay_diagnostics") private var diagnostics: Bool = false
    @State private var showProjectManager = false
    @State private var showFileBrowser = false
    /// When set, present the Create-chat sheet for this agent. Cleared
    /// after the user finishes (or cancels) — the new session is
    /// resumed from the sheet's onCreated callback.
    @State private var createChatAgent: Agent? = nil
    /// When set, present the Endpoint-check sheet for this agent.
    @State private var endpointCheckAgent: Agent? = nil
    /// When non-nil, present the "Compact this session?" confirm dialog
    /// against this session id. Cleared on confirm / cancel.
    @State private var compactConfirmSessionId: String? = nil
    /// Server-side error text from the last compaction trigger, surfaced
    /// as an alert when non-nil.
    @State private var compactError: String? = nil

    /// Per-session file tabs for the iPad central pane. Ephemeral —
    /// cleared whenever the active session changes. The conversation is
    /// always the implicit leading tab (id `"conversation"`) and can't be
    /// closed; file tabs append after it.
    struct FileTabState: Identifiable, Equatable {
        let tabId: String         // `${kind}:${targetId}:${path}` — stable
        let kind: APIClient.FsKind
        let targetId: String
        let path: String
        let server: String?
        let scope: String         // project_id (project) or ark agent_name
        var dirty: Bool

        var id: String { tabId }
    }
    @State private var openFileTabs: [FileTabState] = []
    /// Which file tab is currently shown in the top split pane. nil when
    /// no files are open (conversation takes the full pane).
    @State private var activeTabId: String? = nil
    /// Persisted height of the file pane above the splitter. Defaults to
    /// a comfortable starting size; users can drag the splitter to taste.
    @AppStorage("relay_file_pane_height") private var filePaneHeight: Double = 380

    init(authService: AuthService, themeManager: ThemeManager) {
        self.authService = authService
        self.themeManager = themeManager
        _relay = State(initialValue: RelayViewModel(authService: authService))
    }

    private var currentMessages: [Message] {
        relay.activeSessionId != nil ? relay.sessionMessages : relay.lobbyMessages
    }

    private var isRegular: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if isRegular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .background(theme.surface)
        .fullScreenCover(isPresented: $showSettings) {
            AgentManagementView(
                agents: relay.agents,
                authService: authService,
                themeManager: themeManager,
                onChanged: { Task { await relay.refreshAgents() } }
            )
            .environment(\.relayTheme, themeManager.current)
            .environment(\.relayChatFontSize, themeManager.chatFontSize)
        }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing { Task { await relay.fetchPlatformSettings() } }
        }
        .fullScreenCover(isPresented: $showMenu) {
            menuSheet
        }
        .fullScreenCover(isPresented: $showActivityLog) {
            ActivityLogView()
                .environment(\.relayTheme, themeManager.current)
        }
        .sheet(isPresented: $showLabelEditor) {
            labelEditorSheet
        }
        .sheet(isPresented: $showProjectManager) {
            ProjectManagerView(relay: relay)
                .environment(\.relayTheme, themeManager.current)
        }
        .sheet(item: $createChatAgent) { agent in
            CreateChatSheet(
                relay: relay,
                agent: agent,
                onCreated: { sessionId in
                    Task {
                        // Pull the freshly-created session into the list,
                        // then enter it directly — no operator round-trip.
                        await relay.fetchSessions()
                        await relay.resumeSession(sessionId)
                    }
                },
            )
            .environment(\.relayTheme, themeManager.current)
        }
        .sheet(item: $endpointCheckAgent) { agent in
            EndpointCheckSheet(relay: relay, agent: agent)
                .environment(\.relayTheme, themeManager.current)
        }
        .sheet(isPresented: $showFileBrowser) {
            if let s = activeSession {
                // On iPad, files open into central-pane tabs (the sheet
                // dismisses itself after the callback runs); on iPhone we
                // pass nil and the sheet keeps its inline preview/edit
                // behavior — there's no central tab area on phone.
                FileBrowserView(
                    relay: relay,
                    session: s,
                    onOpenFile: horizontalSizeClass == .regular
                        ? { kind, targetId, path, server in
                            let scope: String = (kind == .project)
                                ? targetId
                                : (relay.agents.first(where: { $0.agentId == s.agentId })
                                    .map { agent in
                                        agent.llmModel.hasPrefix("ark:")
                                            ? String(agent.llmModel.dropFirst("ark:".count))
                                            : agent.llmModel
                                    } ?? s.agentName)
                            openFileTab(
                                kind: kind, targetId: targetId, path: path,
                                server: server, scope: scope,
                            )
                        }
                        : nil,
                )
                .environment(\.relayTheme, themeManager.current)
            }
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
        .modifier(CompactSessionAlerts(
            compactConfirmSessionId: $compactConfirmSessionId,
            compactError: $compactError,
            onConfirm: { sid in
                Task {
                    do { try await relay.compactSession(sid) }
                    catch { compactError = String(describing: error) }
                }
            },
        ))
        .modifier(DirtyCloseAlert(
            pendingCloseTabId: $pendingCloseTabId,
            tabPath: { tid in openFileTabs.first(where: { $0.tabId == tid })?.path },
            onDiscard: { tid in doCloseFileTab(tid) }
        ))
        .task { await relay.connect() }
        .onDisappear { Task { await relay.disconnect() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    // Always resync on foreground — the app may have missed messages
                    // while backgrounded, especially if the agent finished in the background.
                    if !relay.connected {
                        await relay.reconnect()
                    } else {
                        // Connection appears alive but may be stale — resync session state
                        await relay.resync()
                    }
                }
            }
        }
        .onChange(of: relay.connected) { _, isConnected in
            if !isConnected && scenePhase == .active {
                Task { await relay.reconnect() }
            }
        }
        .onChange(of: sidebarSearchQuery) { _, q in
            Task { await relay.fetchSessions(search: q, label: sidebarLabelFilter) }
        }
        .onChange(of: sidebarLabelFilter) { _, l in
            Task { await relay.fetchSessions(search: sidebarSearchQuery, label: l) }
        }
        .onChange(of: menuSearchQuery) { _, q in
            Task { await relay.fetchSessions(search: q, label: menuLabelFilter) }
        }
        .onChange(of: menuLabelFilter) { _, l in
            Task { await relay.fetchSessions(search: menuSearchQuery, label: l) }
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
                    // Use reconnect (not connect) so any previously-active session
                    // is re-established on the server side — otherwise the next
                    // message would be routed to the lobby.
                    await relay.reconnect()
                    relay.enterLiveMode()
                }
            } else if !relay.isLiveMode {
                relay.enterLiveMode()
            }
        }
        .onKeyPress("/") {
            // Don't steal single-letter shortcuts while the user is typing
            // in any UIKit-backed text view — first-responder state isn't
            // visible to SwiftUI's FocusState, so we check view-model
            // flags the wrappers set instead.
            if relay.editorFocused { return .ignored }
            if isRegular && !relay.messageInputFocused && !sidebarSearchFocused {
                sidebarSearchFocused = true
                return .handled
            }
            return .ignored
        }
        .onKeyPress("m") {
            if relay.editorFocused { return .ignored }
            if !relay.messageInputFocused && !sidebarSearchFocused {
                relay.messageInputFocused = true
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            // Editor focused → ask it to resign first responder.
            if relay.editorFocused {
                relay.resignEditorFocusTrigger &+= 1
                return .handled
            }
            if relay.messageInputFocused {
                relay.messageInputFocused = false
                return .handled
            }
            if sidebarSearchFocused { sidebarSearchFocused = false; return .handled }
            return .ignored
        }
    }

    // MARK: - iPhone Layout (unchanged)

    private var iPhoneLayout: some View {
        VStack(spacing: 0) {
            iPhoneHeader

            // Agent cards — only when in lobby
            if relay.connected && relay.activeSessionId == nil {
                AgentSelector(
                    agents: relay.agents,
                    activeAgentName: relay.activeAgentName,
                    onSelect: { agent in
                        Task { await relay.sendMessage("connect me to \(agent.name)") }
                    },
                    onCreateChat: { agent in createChatAgent = agent },
                    onEndpointCheck: { agent in endpointCheckAgent = agent }
                )
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.border).frame(height: theme.borderWidth)
                }
            }

            sessionLabelsBar

            ConversationLog(
                messages: currentMessages,
                activeSessionId: relay.activeSessionId,
                activeAgentName: relay.activeAgentName,
                connected: relay.connected,
                diagnostics: diagnostics
            )
            .frame(maxHeight: .infinity)

            if activeSessionIsArk {
                AgentActivityStrip(relay: relay)
            }
            CompactingChip(relay: relay)
            InputBar(relay: relay, messageFocus: $relay.messageInputFocused)
        }
    }

    private var iPhoneHeader: some View {
        HStack(spacing: 12) {
            Button(action: { showMenu = true }) {
                ThemedIcon(systemName: "line.3.horizontal")
                    .font(theme.bodyFont(size: 22))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            StatusOrb(
                activeSpeaker: relay.activeSpeaker,
                status: relay.status,
                connected: relay.connected,
                compact: true
            )

            Text(relay.activeAgentName ?? "Operator")
                .font(theme.headingFont(size: 20))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer()

            if relay.activeSessionId != nil {
                if fileBrowserAvailable {
                    Button(action: { showFileBrowser = true }) {
                        ThemedIcon(systemName: "folder")
                            .font(theme.bodyFont(size: 18, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(theme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                }
                sessionKebabMenu

                Button(action: { Task { await relay.leaveSession() } }) {
                    ThemedIcon(systemName: "xmark.circle.fill")
                        .font(theme.bodyFont(size: 18, weight: .semibold))
                        .foregroundStyle(theme.warning)
                        .frame(width: 44, height: 44)
                        .background(theme.warning.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
    }

    // MARK: - iPad Layout

    private var iPadLayout: some View {
        HStack(spacing: 0) {
            iPadSidebar
                .frame(width: 280)

            Rectangle().fill(theme.border).frame(width: theme.borderWidth)

            iPadMainContent
        }
    }

    private var iPadSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sidebar header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Relay")
                        .font(theme.headingFont(size: 20))
                        .foregroundStyle(theme.textPrimary)
                    Text(relay.activeAgentName.map { "Session with \($0)" } ?? "Lobby")
                        .font(theme.monoFont(size: 20))
                        .foregroundStyle(theme.textQuaternary)
                }

                Spacer()

                Button(action: { showProjectManager = true }) {
                    ThemedIcon(systemName: "folder")
                        .font(theme.bodyFont(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 24, height: 24)
                        .background(theme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                .help("Projects")

                Button(action: { showSettings = true }) {
                    ThemedIcon(systemName: "gearshape")
                        .font(theme.bodyFont(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 24, height: 24)
                        .background(theme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Agents section
                    if relay.connected {
                        sidebarAgentsSection
                    }

                    // Label filter
                    let allLabels = relay.allLabels
                    if !allLabels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("LABELS")
                                .font(theme.labelFont(size: 12))
                                .tracking(1.5)
                                .foregroundStyle(theme.textQuaternary)
                                .padding(.horizontal, 16)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(allLabels, id: \.self) { label in
                                        Button {
                                            sidebarLabelFilter = sidebarLabelFilter == label ? nil : label
                                        } label: {
                                            Text(label)
                                                .font(theme.bodyFont(size: 20, weight: .medium))
                                                .foregroundStyle(sidebarLabelFilter == label ? .white : theme.primary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(sidebarLabelFilter == label ? theme.primary : theme.primary.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // Sessions section
                    if !relay.sessions.isEmpty {
                        sidebarSessionsSection
                    }
                }
                .padding(.vertical, 12)
            }

            // Logout
            Button(action: { authService.logout() }) {
                ThemedLabel(title: "Logout", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(theme.bodyFont(size: 13))
                    .foregroundStyle(theme.textQuaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
            }
        }
        .background(theme.surface.opacity(0.5))
    }

    private var sidebarAgentsSection: some View {
        let visibleAgents = relay.agents
            .filter { !$0.isOperator }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }

        return VStack(alignment: .leading, spacing: 6) {
            Text("AGENTS")
                .font(theme.labelFont(size: 12))
                .tracking(1.5)
                .foregroundStyle(theme.textQuaternary)
                .padding(.horizontal, 16)

            VStack(spacing: 2) {
                ForEach(visibleAgents) { agent in
                    let isActive = agent.name.lowercased() == (relay.activeAgentName ?? "").lowercased()
                    Button {
                        Task { await relay.sendMessage("connect me to \(agent.name)") }
                    } label: {
                        HStack(spacing: 8) {
                            StatusIndicator(
                                color: agent.status == .healthy ? theme.success
                                      : agent.status == .error ? theme.error
                                      : theme.primary
                            )

                            Text(agent.name)
                                .font(theme.bodyFont(size: 13, weight: .medium))
                                .foregroundStyle(isActive ? theme.successLight : theme.textSecondary)

                            Spacer()

                            Text(agent.llmProvider)
                                .font(theme.monoFont(size: 18))
                                .foregroundStyle(theme.textQuaternary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isActive ? theme.agentActive : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if agent.llmProvider == "ark" {
                            Button {
                                createChatAgent = agent
                            } label: {
                                Label("Create chat…", systemImage: "plus.bubble")
                            }
                        }
                        Button {
                            endpointCheckAgent = agent
                        } label: {
                            Label("Endpoint check", systemImage: "stethoscope")
                        }
                    }
                }
            }
        }
    }

    private var activeSession: Session? {
        relay.sessions.first(where: { $0.sessionId == relay.activeSessionId })
    }

    /// The Files affordance shows when the active session is ark-backed
    /// (workspace tab applicable) or bound to a project. Other providers
    /// have no filesystem to expose.
    private var fileBrowserAvailable: Bool {
        guard let s = activeSession else { return false }
        if s.projectId != nil { return true }
        return relay.agents.first(where: { $0.agentId == s.agentId })?.llmProvider == "ark"
    }

    /// True when the active session is backed by an ark agent — the
    /// only case where compaction is meaningful (other providers don't
    /// expose the endpoint).
    private var activeSessionIsArk: Bool {
        guard let s = activeSession else { return false }
        return relay.agents.first(where: { $0.agentId == s.agentId })?.llmProvider == "ark"
    }

    /// True while ark is compacting the active session — used to disable
    /// the menu item so the user can't kick off a second compaction
    /// while one is running.
    private var activeSessionIsCompacting: Bool {
        guard let sid = relay.activeSessionId else { return false }
        return relay.compacting[sid] != nil
    }

    /// Look up the project name for a session's `projectId` against the
    /// view-model's cached projects list. Returns nil if the session isn't
    /// bound or the project hasn't loaded yet.
    private func projectName(for session: Session) -> String? {
        guard let pid = session.projectId else { return nil }
        return relay.projects.first(where: { $0.id == pid })?.name
    }

    private var sidebarSessionsSection: some View {
        let filtered = relay.sessions.filter { session in
            if let filter = sidebarLabelFilter, !session.labels.contains(filter) { return false }
            if !sidebarSearchQuery.isEmpty {
                let q = sidebarSearchQuery.lowercased()
                // Search hits name / agent / labels / project name — chips and
                // labels share the same conceptual space.
                var haystack = (session.name ?? "").lowercased()
                haystack += " " + session.agentName.lowercased()
                haystack += " " + session.labels.joined(separator: " ").lowercased()
                if let pn = projectName(for: session) { haystack += " " + pn.lowercased() }
                if !haystack.contains(q) { return false }
            }
            return true
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sidebarLabelFilter.map { "SESSIONS: \($0.uppercased())" } ?? "SESSIONS")
                    .font(theme.labelFont(size: 12))
                    .tracking(1.5)
                    .foregroundStyle(theme.textQuaternary)

                HStack(spacing: 4) {
                    TextField("/", text: $sidebarSessionSearch)
                        .font(theme.monoFont(size: 14))
                        .foregroundStyle(theme.textSecondary)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(theme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                        .focused($sidebarSearchFocused)
                        .onSubmit {
                            sidebarSearchQuery = sidebarSessionSearch
                        }
                    if !sidebarSessionSearch.isEmpty || !sidebarSearchQuery.isEmpty {
                        Button {
                            sidebarSessionSearch = ""
                            sidebarSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.textQuaternary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                    .onKeyPress(.escape) {
                        sidebarSessionSearch = ""
                        sidebarSearchQuery = ""
                        sidebarSearchFocused = false
                        return .handled
                    }
                    .onKeyPress("/") {
                        if !sidebarSearchFocused {
                            sidebarSearchFocused = true
                            return .handled
                        }
                        return .ignored
                    }
            }
            .padding(.horizontal, 16)

            VStack(spacing: 2) {
                ForEach(filtered.prefix(15)) { session in
                    let isActive = relay.activeSessionId == session.sessionId
                    Button {
                        Task { await relay.resumeSession(session.sessionId) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if session.status == "processing" {
                                    BlinkingIndicator(color: theme.primary, size: 6)
                                } else if session.hasUnread {
                                    StatusIndicator(color: theme.primary, size: 6)
                                }
                                Text(session.name ?? session.agentName)
                                    .font(theme.bodyFont(size: 13, weight: .medium))
                                    .foregroundStyle(isActive ? theme.successLight : theme.textSecondary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 4) {
                                Text(session.agentName)
                                    .font(theme.monoFont(size: 18))
                                    .foregroundStyle(theme.textQuaternary)
                                Text("·")
                                    .foregroundStyle(theme.textQuaternary)
                                Text(session.status)
                                    .font(theme.monoFont(size: 18))
                                    .foregroundStyle(theme.textQuaternary)
                            }

                            if !session.labels.isEmpty || projectName(for: session) != nil {
                                HStack(spacing: 3) {
                                    if let pn = projectName(for: session) {
                                        Text(pn)
                                            .font(theme.monoFont(size: 18, weight: .medium))
                                            .foregroundStyle(theme.success)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(theme.success.opacity(0.18))
                                            .clipShape(Capsule())
                                    }
                                    ForEach(session.labels.prefix(3), id: \.self) { label in
                                        Text(label)
                                            .font(theme.monoFont(size: 18, weight: .medium))
                                            .foregroundStyle(theme.primary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(theme.primary.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                            }

                            if let summary = session.summary {
                                Text(summary)
                                    .font(theme.bodyFont(size: 20))
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isActive ? theme.agentActive : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameSessionId = session.sessionId
                            renameText = session.name ?? ""
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button {
                            // Prefer the ark server-side session id when
                            // present — that's what `post_to_session` and
                            // cron entries reference. Fall back to Relay's
                            // own id for non-ark sessions.
                            let id = session.providerState["ark"] ?? session.sessionId
                            UIPasteboard.general.string = id
                        } label: {
                            Label("Copy Session ID", systemImage: "doc.on.doc")
                        }

                        Button(role: .destructive) {
                            Task { await relay.deleteSession(session.sessionId) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var iPadMainContent: some View {
        VStack(spacing: 0) {
            iPadHeader

            sessionLabelsBar

            // Top split — only visible when files are open. Conversation
            // lives below permanently so the user can chat while watching
            // a file.
            if relay.activeSessionId != nil && !openFileTabs.isEmpty {
                VStack(spacing: 0) {
                    iPadTabBar
                    if let tab = openFileTabs.first(where: { $0.tabId == activeTabId }) {
                        FileEditorView(
                            relay: relay,
                            kind: tab.kind,
                            targetId: tab.targetId,
                            path: tab.path,
                            server: tab.server,
                            scope: tab.scope,
                            onDirtyChange: { dirty in setTabDirty(tab.tabId, dirty: dirty) },
                        )
                        .id(tab.tabId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer()
                    }
                }
                .frame(height: filePaneHeight)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.border).frame(height: theme.borderWidth)
                }

                splitHandle
            }

            // Conversation pane — always at the bottom of the layout.
            VStack(spacing: 0) {
                ConversationLog(
                    messages: currentMessages,
                    activeSessionId: relay.activeSessionId,
                    activeAgentName: relay.activeAgentName,
                    connected: relay.connected,
                    diagnostics: diagnostics
                )
                .frame(maxHeight: .infinity)

                if activeSessionIsArk {
                AgentActivityStrip(relay: relay)
            }
            CompactingChip(relay: relay)
            InputBar(relay: relay, messageFocus: $relay.messageInputFocused)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: relay.activeSessionId) { _, _ in
            // Ephemeral tabs: leaving the session ditches every open editor.
            openFileTabs = []
            activeTabId = nil
        }
    }

    /// Drag handle between the file pane and the conversation. Drag down
    /// to grow the file pane, drag up to grow the conversation. Height is
    /// clamped and persisted to `@AppStorage` so it sticks across opens.
    /// Reads as a distinct band with a centered grip so users can see it's
    /// interactive — earlier revisions blended into the surface fill.
    @ViewBuilder
    private var splitHandle: some View {
        ZStack {
            theme.elevated
            // Centered grip — a short pill that telegraphs draggability.
            Capsule()
                .fill(theme.textQuaternary)
                .frame(width: 36, height: 3)
        }
        .frame(height: 12)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let next = filePaneHeight + value.translation.height
                    filePaneHeight = max(120, min(900, next))
                }
                .onEnded { _ in
                    filePaneHeight = max(120, min(900, filePaneHeight))
                }
        )
    }

    @ViewBuilder
    private var iPadTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(openFileTabs) { tab in
                    let filename = tab.path.split(separator: "/").last.map(String.init) ?? tab.path
                    tabButton(
                        label: filename,
                        active: activeTabId == tab.tabId,
                        dirty: tab.dirty,
                        onTap: { activeTabId = tab.tabId },
                        onClose: { closeFileTab(tab.tabId) },
                    )
                }
            }
        }
        .frame(height: 34)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
    }

    private func tabButton(
        label: String, active: Bool, dirty: Bool,
        onTap: @escaping () -> Void, onClose: (() -> Void)?,
    ) -> some View {
        HStack(spacing: 4) {
            if dirty {
                Circle().fill(theme.warning).frame(width: 6, height: 6)
            }
            Button(action: onTap) {
                Text(label)
                    .font(theme.bodyFont(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? theme.textPrimary : theme.textQuaternary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            if let close = onClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textQuaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(active ? theme.elevated : Color.clear)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.border).frame(width: theme.borderWidth)
        }
    }

    // MARK: - Tab actions

    private func openFileTab(
        kind: APIClient.FsKind, targetId: String, path: String,
        server: String?, scope: String,
    ) {
        let tabId = "\(kind.rawValue):\(targetId):\(path)"
        if openFileTabs.first(where: { $0.tabId == tabId }) == nil {
            openFileTabs.append(
                FileTabState(
                    tabId: tabId, kind: kind, targetId: targetId,
                    path: path, server: server, scope: scope, dirty: false,
                ),
            )
        }
        activeTabId = tabId
    }

    private func closeFileTab(_ tabId: String) {
        // If the tab has unsaved edits, route through the confirm alert
        // so the user can explicitly discard or back out. Clean tabs
        // close immediately.
        if let tab = openFileTabs.first(where: { $0.tabId == tabId }), tab.dirty {
            pendingCloseTabId = tabId
            return
        }
        doCloseFileTab(tabId)
    }

    /// Actually drops the tab from state — invoked either directly (clean
    /// tab) or after the user confirms the discard.
    private func doCloseFileTab(_ tabId: String) {
        let wasActive = activeTabId == tabId
        openFileTabs.removeAll(where: { $0.tabId == tabId })
        if wasActive {
            // Fall back to the last remaining tab, or nil if we just
            // closed the only open file — the split pane collapses.
            activeTabId = openFileTabs.last?.tabId
        }
    }

    private func setTabDirty(_ tabId: String, dirty: Bool) {
        guard let idx = openFileTabs.firstIndex(where: { $0.tabId == tabId }) else { return }
        if openFileTabs[idx].dirty != dirty {
            openFileTabs[idx].dirty = dirty
        }
    }

    private var iPadHeader: some View {
        HStack(spacing: 12) {
            StatusOrb(
                activeSpeaker: relay.activeSpeaker,
                status: relay.status,
                connected: relay.connected,
                compact: true
            )

            Text(relay.activeAgentName ?? "Operator")
                .font(theme.headingFont(size: 20))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer()

            if relay.activeSessionId != nil {
                if fileBrowserAvailable {
                    Button(action: { showFileBrowser = true }) {
                        ThemedIcon(systemName: "folder")
                            .font(theme.bodyFont(size: 18, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(theme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                }
                sessionKebabMenu

                Button(action: { Task { await relay.leaveSession() } }) {
                    ThemedIcon(systemName: "xmark.circle.fill")
                        .font(theme.bodyFont(size: 18, weight: .semibold))
                        .foregroundStyle(theme.warning)
                        .frame(width: 44, height: 44)
                        .background(theme.warning.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: theme.borderWidth)
        }
    }

    // MARK: - Shared Components

    private var sessionKebabMenu: some View {
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

            Button {
                diagnostics.toggle()
            } label: {
                // Checkmark image on the Label conveys the toggle state inside
                // a Menu without needing a separate Toggle widget.
                Label(
                    "Diagnostics",
                    systemImage: diagnostics ? "checkmark.circle.fill" : "info.circle"
                )
            }

            if activeSessionIsArk {
                Button {
                    compactError = nil
                    compactConfirmSessionId = relay.activeSessionId
                } label: {
                    Label("Compact Session", systemImage: "text.append")
                }
                .disabled(activeSessionIsCompacting)
            }
        } label: {
            ThemedIcon(systemName: "ellipsis")
                .font(theme.bodyFont(size: 24, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 48, height: 48)
                .background(theme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }

    @ViewBuilder
    private var sessionLabelsBar: some View {
        if relay.activeSessionId != nil {
            let sessionName = relay.sessions.first(where: { $0.sessionId == relay.activeSessionId })?.name

            VStack(alignment: .leading, spacing: 4) {
                Text(sessionName ?? "<New session>")
                    .font(theme.monoFont(size: 18))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)

                if !relay.activeSessionLabels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(relay.activeSessionLabels, id: \.self) { label in
                                Text(label)
                                    .font(theme.bodyFont(size: 20, weight: .medium))
                                    .foregroundStyle(theme.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(theme.primary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
            }
        }
    }

    // MARK: - Menu Sheet (iPhone only)

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
                        ThemedLabel(title: "Settings", systemImage: "gearshape")
                            .foregroundStyle(theme.textPrimary)
                    }

                    Button(action: {
                        showMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showProjectManager = true
                        }
                    }) {
                        ThemedLabel(title: "Projects", systemImage: "folder")
                            .foregroundStyle(theme.textPrimary)
                    }

                    Button(action: {
                        showMenu = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showActivityLog = true
                        }
                    }) {
                        ThemedLabel(title: "Activity Log", systemImage: "list.bullet.rectangle")
                            .foregroundStyle(theme.textPrimary)
                    }

                    Button(role: .destructive, action: {
                        showMenu = false
                        authService.logout()
                    }) {
                        ThemedLabel(title: "Logout", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(theme.error)
                    }
                }

                if !relay.sessions.isEmpty {
                    // Label filter chips
                    let allLabels = relay.allLabels
                    if !allLabels.isEmpty {
                        Section(header: Text("Labels").font(theme.labelFont(size: 12)).tracking(1).foregroundStyle(theme.primary)) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(allLabels, id: \.self) { label in
                                        Button {
                                            menuLabelFilter = menuLabelFilter == label ? nil : label
                                        } label: {
                                            Text(label)
                                                .font(theme.bodyFont(size: 18, weight: .medium))
                                                .foregroundStyle(menuLabelFilter == label ? .white : theme.primary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(menuLabelFilter == label ? theme.primary : theme.primary.opacity(0.15))
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

                    let filteredSessions = relay.sessions.filter { session in
                        if let filter = menuLabelFilter, !session.labels.contains(filter) { return false }
                        if !menuSearchQuery.isEmpty {
                            let q = menuSearchQuery.lowercased()
                            var haystack = (session.name ?? "").lowercased()
                            haystack += " " + session.agentName.lowercased()
                            haystack += " " + session.labels.joined(separator: " ").lowercased()
                            if let pn = projectName(for: session) { haystack += " " + pn.lowercased() }
                            if !haystack.contains(q) { return false }
                        }
                        return true
                    }

                    Section(header:
                        VStack(alignment: .leading, spacing: 6) {
                            Text(menuLabelFilter.map { "Sessions: \($0)" } ?? "Recent Sessions")
                                .font(theme.labelFont(size: 12))
                                .tracking(1)
                                .foregroundStyle(theme.primary)
                            HStack(spacing: 4) {
                                TextField("Search sessions...", text: $menuSessionSearch)
                                    .font(theme.bodyFont(size: 16))
                                    .foregroundStyle(theme.textSecondary)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(theme.elevated)
                                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                                    .onSubmit {
                                        menuSearchQuery = menuSessionSearch
                                    }
                                if !menuSessionSearch.isEmpty || !menuSearchQuery.isEmpty {
                                    Button {
                                        menuSessionSearch = ""
                                        menuSearchQuery = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(theme.textQuaternary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    ) {
                        ForEach(filteredSessions.prefix(10)) { session in
                            Button(action: {
                                showMenu = false
                                Task { await relay.resumeSession(session.sessionId) }
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        if session.status == "processing" {
                                            BlinkingIndicator(color: theme.primary, size: 6)
                                        } else if session.hasUnread {
                                            StatusIndicator(color: theme.primary, size: 6)
                                        }
                                        Text(session.name ?? session.agentName)
                                            .font(theme.bodyFont(size: 16, weight: .medium))
                                            .foregroundStyle(theme.textSecondary)
                                            .lineLimit(1)
                                    }

                                    HStack(spacing: 4) {
                                        Text(session.agentName)
                                            .font(theme.monoFont(size: 14))
                                            .foregroundStyle(theme.textQuaternary)

                                        Text("·")
                                            .foregroundStyle(theme.textQuaternary)

                                        Text(session.status)
                                            .font(theme.monoFont(size: 14))
                                            .foregroundStyle(theme.textQuaternary)
                                    }

                                    if !session.labels.isEmpty || projectName(for: session) != nil {
                                        HStack(spacing: 4) {
                                            if let pn = projectName(for: session) {
                                                Text(pn)
                                                    .font(theme.monoFont(size: 18, weight: .medium))
                                                    .foregroundStyle(theme.success)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(theme.success.opacity(0.18))
                                                    .clipShape(Capsule())
                                            }
                                            ForEach(session.labels, id: \.self) { label in
                                                Text(label)
                                                    .font(theme.monoFont(size: 18, weight: .medium))
                                                    .foregroundStyle(theme.primary)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(theme.primary.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }

                                    if let summary = session.summary {
                                        Text(summary)
                                            .font(theme.bodyFont(size: 14))
                                            .foregroundStyle(theme.textTertiary)
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
                            .contextMenu {
                                Button {
                                    let id = session.providerState["ark"] ?? session.sessionId
                                    UIPasteboard.general.string = id
                                } label: {
                                    Label("Copy Session ID", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Menu")
                        .font(theme.headingFont(size: 18))
                        .foregroundStyle(theme.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMenu = false } label: {
                        Text("Done")
                            .font(theme.bodyFont(size: 16, weight: .medium))
                            .foregroundStyle(theme.primary)
                    }
                }
            }
        }
        .background(theme.surface)
    }

    // MARK: - Label Editor Sheet

    private var labelEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if relay.activeSessionLabels.isEmpty {
                    Text("No labels yet")
                        .font(theme.bodyFont(size: 14))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 16)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(relay.activeSessionLabels, id: \.self) { label in
                                HStack(spacing: 4) {
                                    Text(label)
                                        .font(theme.bodyFont(size: 20, weight: .medium))
                                        .foregroundStyle(theme.primary)

                                    Button {
                                        guard let sessionId = relay.activeSessionId else { return }
                                        let newLabels = relay.activeSessionLabels.filter { $0 != label }
                                        Task { await relay.updateSessionLabels(sessionId, labels: newLabels) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(theme.bodyFont(size: 18))
                                            .foregroundStyle(theme.primary.opacity(0.6))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(theme.primary.opacity(0.15))
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

                // Existing labels as quick-add suggestions. Sourced from
                // `relay.allLabels` (server-side authoritative list) — using
                // `relay.sessions.flatMap(\.labels)` would only surface
                // labels that happen to be on a session in the recent slice
                // currently in memory, hiding labels on older sessions.
                let existingLabels = relay.allLabels
                    .filter { !relay.activeSessionLabels.contains($0) }
                if !existingLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Existing Labels")
                            .font(theme.labelFont(size: 14))
                            .foregroundStyle(theme.textQuaternary)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(existingLabels, id: \.self) { label in
                                    Button {
                                        guard let sessionId = relay.activeSessionId else { return }
                                        let newLabels = relay.activeSessionLabels + [label]
                                        Task { await relay.updateSessionLabels(sessionId, labels: newLabels) }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(theme.bodyFont(size: 18))
                                            Text(label)
                                                .font(theme.bodyFont(size: 20, weight: .medium))
                                        }
                                        .foregroundStyle(theme.textTertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(theme.elevated)
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

/// Confirm + error alerts for the "Compact session" action. Extracted
/// into a `ViewModifier` for the same reason as `DirtyCloseAlert` —
/// chaining two more `.alert(...)` calls onto RelayView's body tips
/// the SwiftUI type-checker over.
private struct CompactSessionAlerts: ViewModifier {
    @Binding var compactConfirmSessionId: String?
    @Binding var compactError: String?
    let onConfirm: (String) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Compact this session?",
                isPresented: Binding(
                    get: { compactConfirmSessionId != nil },
                    set: { if !$0 { compactConfirmSessionId = nil } },
                ),
            ) {
                Button("Compact") {
                    // Dismiss right away — the visible UI update (chip,
                    // then divider) arrives via the WS event stream, and
                    // any POST error is surfaced by the sibling alert.
                    if let sid = compactConfirmSessionId {
                        compactConfirmSessionId = nil
                        onConfirm(sid)
                    }
                }
                Button("Cancel", role: .cancel) { compactConfirmSessionId = nil }
            } message: {
                Text("The agent will summarize the conversation so far. Older turns stay visible, but the agent will only see the summary from the next message on.")
            }
            .alert(
                "Compaction failed",
                isPresented: Binding(
                    get: { compactError != nil },
                    set: { if !$0 { compactError = nil } },
                ),
            ) {
                Button("OK", role: .cancel) { compactError = nil }
            } message: {
                Text(compactError ?? "")
            }
    }
}

/// Pulled out as a `ViewModifier` because inlining its `.alert(...)` chain
/// into `RelayView`'s already-large `body` blew past Swift's type-check
/// budget. Same behavior either way.
private struct DirtyCloseAlert: ViewModifier {
    @Binding var pendingCloseTabId: String?
    let tabPath: (String) -> String?
    let onDiscard: (String) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { pendingCloseTabId != nil },
                set: { if !$0 { pendingCloseTabId = nil } }
            ),
            presenting: pendingCloseTabId,
        ) { tid in
            Button("Discard", role: .destructive) {
                onDiscard(tid)
                pendingCloseTabId = nil
            }
            Button("Cancel", role: .cancel) { pendingCloseTabId = nil }
        } message: { tid in
            if let p = tabPath(tid) {
                Text("\(p) has unsaved changes.")
            } else {
                Text("Unsaved changes will be lost.")
            }
        }
    }
}
