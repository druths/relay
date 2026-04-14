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
    @State private var showRenameAlert = false
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
        .onKeyPress("/") {
            if isRegular {
                sidebarSearchFocused = true
                return .handled
            }
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
                    }
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
                connected: relay.connected
            )
            .frame(maxHeight: .infinity)

            InputBar(relay: relay)
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

                Button(action: { showSettings = true }) {
                    ThemedIcon(systemName: "gearshape")
                        .font(theme.bodyFont(size: 16))
                        .foregroundStyle(theme.textTertiary)
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
                    let allLabels = Array(Set(relay.sessions.flatMap(\.labels))).sorted()
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
                }
            }
        }
    }

    private var sidebarSessionsSection: some View {
        let filtered = relay.sessions.filter { session in
            if let filter = sidebarLabelFilter, !session.labels.contains(filter) { return false }
            if !sidebarSearchQuery.isEmpty {
                let name = (session.name ?? session.agentName).lowercased()
                if !name.contains(sidebarSearchQuery.lowercased()) { return false }
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

                            if !session.labels.isEmpty {
                                HStack(spacing: 3) {
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

            ConversationLog(
                messages: currentMessages,
                activeSessionId: relay.activeSessionId,
                activeAgentName: relay.activeAgentName,
                connected: relay.connected
            )
            .frame(maxHeight: .infinity)

            InputBar(relay: relay)
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
                    let allLabels = Array(Set(relay.sessions.flatMap(\.labels))).sorted()
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
                            let name = (session.name ?? session.agentName).lowercased()
                            if !name.contains(menuSearchQuery.lowercased()) { return false }
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

                                    if !session.labels.isEmpty {
                                        HStack(spacing: 4) {
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

                // Existing labels as quick-add suggestions
                let existingLabels = Array(Set(relay.sessions.flatMap(\.labels)))
                    .sorted()
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
