import SwiftUI

struct AgentManagementView: View {
    let agents: [Agent]
    let authService: AuthService
    let themeManager: ThemeManager?
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme
    @State private var vm: AgentManagementViewModel
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showUnsavedAlert = false
    @State private var pendingAction: (() -> Void)?

    init(agents: [Agent], authService: AuthService, themeManager: ThemeManager? = nil, onChanged: @escaping () -> Void) {
        self.agents = agents
        self.authService = authService
        self.themeManager = themeManager
        self.onChanged = onChanged
        _vm = State(initialValue: AgentManagementViewModel(apiClient: APIClient(authService: authService)))
    }

    private var sortedAgents: [Agent] {
        agents.sorted {
            if $0.isOperator { return true }
            if $1.isOperator { return false }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name < $1.name
        }
    }

    private var nonOperatorAgents: [Agent] {
        sortedAgents.filter { !$0.isOperator }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                tabContent
            }
            .background(theme.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { attemptAction { dismiss() } }
                }
            }
            .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Unsaved Changes", isPresented: $showUnsavedAlert, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) {
                    pendingAction?()
                    pendingAction = nil
                }
                Button("Keep Editing", role: .cancel) {
                    pendingAction = nil
                }
            } message: {
                Text("You have unsaved changes that will be lost.")
            }
        }
        .task {
            await vm.loadPlatformSettings()
            if let first = sortedAgents.first {
                vm.selectAgent(first)
                await vm.fetchTtsModels()
                await vm.fetchVoices()
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AgentManagementViewModel.Tab.allCases, id: \.self) { tab in
                    Button(action: {
                        guard vm.selectedTab != tab else { return }
                        attemptAction { vm.selectedTab = tab }
                    }) {
                        Text(tab.rawValue)
                            .font(theme.bodyFont(size: 20, weight: .medium))
                            .foregroundStyle(vm.selectedTab == tab ? theme.textPrimary : theme.textQuaternary)
                            .fixedSize()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(vm.selectedTab == tab ? theme.border : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.elevated).frame(height: theme.borderWidth)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch vm.selectedTab {
        case .agents:
            agentsTab
        case .tts:
            ttsTab
        case .stt:
            sttTab
        case .appearance:
            appearanceTab
        case .account:
            accountTab
        }
    }

    // MARK: - Agents Tab

    private var agentsTab: some View {
        VStack(spacing: 0) {
            // Agent picker pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sortedAgents) { agent in
                        agentPill(agent)
                    }
                    newAgentPill
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.elevated).frame(height: theme.borderWidth)
            }

            // Reorder controls for selected non-operator agent
            if let selectedId = vm.selectedAgentId,
               !vm.isNewAgent,
               let agent = agents.first(where: { $0.agentId == selectedId }),
               !agent.isOperator {
                let idx = nonOperatorAgents.firstIndex(where: { $0.agentId == selectedId })
                HStack(spacing: 12) {
                    Text("Order")
                        .font(theme.bodyFont(size: 18))
                        .foregroundStyle(theme.textQuaternary)
                    Button {
                        moveAgent(selectedId, direction: -1)
                    } label: {
                        Image(systemName: "arrow.left")
                            .font(theme.bodyFont(size: 18, weight: .medium))
                            .foregroundStyle(idx == 0 ? theme.textQuinary : theme.textSecondary)
                    }
                    .disabled(idx == 0)

                    Button {
                        moveAgent(selectedId, direction: 1)
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(theme.bodyFont(size: 18, weight: .medium))
                            .foregroundStyle(idx == (nonOperatorAgents.count - 1) ? theme.textQuinary : theme.textSecondary)
                    }
                    .disabled(idx == (nonOperatorAgents.count - 1))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.elevated).frame(height: theme.borderWidth)
                }
            }

            // Agent form
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    agentFormContent
                }
                .padding(16)
            }
        }
    }

    private func moveAgent(_ agentId: String, direction: Int) {
        var reordered = nonOperatorAgents
        guard let idx = reordered.firstIndex(where: { $0.agentId == agentId }) else { return }
        let newIdx = idx + direction
        guard newIdx >= 0 && newIdx < reordered.count else { return }
        reordered.swapAt(idx, newIdx)
        let ids = reordered.map(\.agentId)
        Task {
            await vm.reorderAgents(ids: ids)
            onChanged()
        }
    }

    private func agentPill(_ agent: Agent) -> some View {
        let isActive = !vm.isNewAgent && vm.selectedAgentId == agent.agentId
        return Button(action: { vm.selectAgent(agent); Task { await vm.fetchTtsModels(); await vm.fetchVoices() } }) {
            HStack(spacing: 6) {
                StatusIndicator(color: statusColor(agent.status))
                if agent.isOperator {
                    Image(systemName: "lock.fill")
                        .font(theme.bodyFont(size: 18))
                        .foregroundStyle(theme.textQuaternary)
                }
                Text(agent.name)
                    .font(theme.bodyFont(size: 20))
                    .foregroundStyle(isActive ? theme.textPrimary : theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? theme.border : theme.elevated)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var newAgentPill: some View {
        Button(action: { vm.startNewAgent() }) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(theme.bodyFont(size: 18))
                Text("New")
                    .font(theme.bodyFont(size: 20))
            }
            .foregroundStyle(vm.isNewAgent ? theme.primaryLighter : theme.primaryLight)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(vm.isNewAgent ? theme.newAgentPill : theme.elevated)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var agentFormContent: some View {
        let selected = agents.first { $0.agentId == vm.selectedAgentId }

        // Health status
        if let selected {
            HStack(spacing: 8) {
                StatusIndicator(color: statusColor(selected.status))
                Text(selected.status == .healthy ? "Healthy" : selected.status == .error ? (selected.statusMessage.isEmpty ? "Error" : selected.statusMessage) : "Not checked")
                    .font(theme.monoFont(size: 18))
                    .foregroundStyle(theme.textTertiary)

                Spacer()

                Button {
                    Task {
                        if let updated = await vm.checkAgentHealth(selected.agentId) {
                            // Refresh the agent list to reflect new status
                            onChanged()
                        }
                    }
                } label: {
                    Text("Check now")
                        .font(theme.bodyFont(size: 18))
                        .foregroundStyle(theme.primary)
                }
            }
            .padding(.bottom, 12)
        }

        // Name
        sectionLabel("Name")
        formTextField("name", placeholder: "Agent name", disabled: selected?.isOperator == true)

        // LLM Provider
        sectionTitle("LLM PROVIDER")
        providerPicker("llm_provider", options: ProviderSchemas.llmProviders.map { ($0.key, $0.schema.label) })

        if let schema = ProviderSchemas.llmSchema(for: vm.form["llm_provider"] ?? "openai") {
            ForEach(schema.fields.filter { $0.key != "llm_model" }, id: \.key) { field in
                sectionLabel(field.label)
                formTextField(field.key, placeholder: field.placeholder, secure: field.fieldType == .password)
            }
        }

        sectionLabel("Model")
        formTextField("llm_model", placeholder: ProviderSchemas.llmSchema(for: vm.form["llm_provider"] ?? "openai")?.fields.first { $0.key == "llm_model" }?.placeholder ?? "model")

        // TTS Provider
        sectionTitle("TTS PROVIDER")
        providerPicker("tts_provider", options: ProviderSchemas.ttsProviders.map { ($0.key, $0.schema.label) })

        if let schema = ProviderSchemas.ttsSchema(for: vm.form["tts_provider"] ?? "none") {
            ForEach(schema.fields, id: \.key) { field in
                sectionLabel(field.label)
                formTextField(field.key, placeholder: field.placeholder, secure: field.fieldType == .password)
                    .onChange(of: vm.form[field.key]) { _, _ in
                        if field.key == "base_url" {
                            Task { await vm.fetchTtsModels(); await vm.fetchVoices() }
                        }
                    }
            }
        }

        let ttsProvider = vm.form["tts_provider"] ?? "none"

        // Voice picker
        if ttsProvider != "none" {
            sectionLabel("Voice")
            Menu {
                ForEach(vm.voices) { voice in
                    Button("\(voice.name) — \(voice.description)") {
                        vm.form["voice_id"] = voice.id
                    }
                }
            } label: {
                HStack {
                    Text(vm.voices.first { $0.id == vm.form["voice_id"] }?.name ?? (vm.voices.isEmpty ? "No voices available" : "Select voice..."))
                        .font(theme.bodyFont(size: 21))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(theme.bodyFont(size: 18))
                        .foregroundStyle(theme.textQuaternary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(theme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            }
            .disabled(vm.voices.isEmpty)
            .opacity(vm.voices.isEmpty ? 0.5 : 1)
        }

        // OpenAI voice settings
        if ttsProvider == "openai" {
            if !vm.ttsModels.isEmpty {
                sectionLabel("Model")
                pickerMenu("model", options: vm.ttsModels.map { ($0.id, $0.name) })
            }

            sliderField("Speed", key: "speed", range: 0.25...4.0, step: 0.25, format: "%.2f")
        }

        // ElevenLabs voice settings
        if ttsProvider == "elevenlabs" {
            sectionLabel("Model")
            pickerMenu("model_id", options: [
                ("eleven_multilingual_v2", "eleven_multilingual_v2"),
                ("eleven_turbo_v2_5", "eleven_turbo_v2_5"),
                ("eleven_flash_v2_5", "eleven_flash_v2_5"),
            ])

            sliderField("Stability", key: "stability", range: 0...1, step: 0.05, format: "%.2f")
            sliderField("Similarity Boost", key: "similarity_boost", range: 0...1, step: 0.05, format: "%.2f")
        }

        // Persona Prompt
        sectionLabel("Persona Prompt")
        TextEditor(text: Binding(
            get: { vm.form["persona_prompt"] ?? "" },
            set: { vm.form["persona_prompt"] = $0 }
        ))
        .font(theme.bodyFont(size: 21))
        .foregroundStyle(theme.textSecondary)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 80)
        .padding(8)
        .background(theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

        // Actions
        HStack(spacing: 12) {
            Button(action: {
                Task {
                    do {
                        _ = try await vm.saveAgent(agents: agents)
                        onChanged()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }) {
                Text(vm.isSaving ? "Saving..." : (vm.isNewAgent ? "Create Agent" : "Save Changes"))
                    .font(theme.bodyFont(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(theme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            }
            .disabled(vm.isSaving)
            .opacity(vm.isSaving ? 0.5 : 1)

            if let selected, !selected.isOperator {
                Button(action: { showDeleteConfirm = true }) {
                    Text("Delete")
                        .font(theme.bodyFont(size: 21, weight: .semibold))
                        .foregroundStyle(theme.error)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(theme.border)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                .confirmationDialog("Delete \"\(selected.name)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        Task {
                            do {
                                try await vm.deleteAgent(selected.agentId)
                                if let first = sortedAgents.first {
                                    vm.selectAgent(first)
                                }
                                onChanged()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 20)
    }

    // MARK: - TTS Tab

    private var ttsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("DEFAULT PROVIDER")
                pickerMenuPlatform("tts_default_provider", options: [("none", "None"), ("openai", "OpenAI"), ("elevenlabs", "ElevenLabs")])
                hintText("The default TTS provider used when creating new agents.")

                separator
                sectionTitle("OPENAI TTS")
                sectionLabel("API Key")
                platformTextField("tts_openai_api_key", placeholder: "sk-... (falls back to env var)", secure: true)
                hintText("Platform-wide OpenAI API key for text-to-speech.")

                separator
                sectionTitle("ELEVENLABS")
                sectionLabel("API Key")
                platformTextField("tts_elevenlabs_api_key", placeholder: "xi-... (falls back to env var)", secure: true)
                hintText("Platform-wide ElevenLabs API key for text-to-speech.")

                separator
                sectionTitle("LIVE VOICE MODE")
                sectionLabel("Voice Instructions")
                hintText("Injected into the agent system prompt when live mode is active. Use this to encourage concise, conversational responses without markdown.")
                TextEditor(text: platformBinding("voice_mode_instructions"))
                    .font(theme.bodyFont(size: 21))
                    .foregroundStyle(theme.textSecondary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

                savePlatformButton
                    .padding(.top, 20)
            }
            .padding(16)
        }
    }

    // MARK: - STT Tab

    private var sttProvider: String {
        vm.platformForm["stt_provider"] ?? "openai"
    }

    private var sttTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("PROVIDER")
                pickerMenuPlatform("stt_provider", options: ProviderSchemas.sttProviders.map { ($0.key, $0.schema.label) })

                if sttProvider == "apple" {
                    hintText("Uses iOS on-device speech recognition. No API key or server-side STT required.")
                } else {
                    sectionLabel("API Key")
                    platformTextField("stt_api_key",
                        placeholder: sttProvider == "elevenlabs"
                            ? "xi-... (falls back to TTS ElevenLabs key)"
                            : "sk-... (falls back to env var)",
                        secure: true
                    )
                }

                separator
                sectionTitle("RECOGNITION TUNING")
                hintText("Adjust these to reduce false transcriptions from ambient noise.")

                platformSlider("Silence Threshold", key: "stt_silence_threshold_db", range: -50...(-10), step: 1, unit: " dB")
                hintText("Minimum dB level to detect speech. Higher = less sensitive.")

                platformSlider("Silence Timeout", key: "stt_silence_timeout_ms", range: 200...2000, step: 50, unit: " ms")
                hintText("How long silence must last before ending a recording.")

                platformSlider("Min Duration", key: "stt_min_duration_ms", range: 200...1000, step: 50, unit: " ms")
                hintText("Recordings shorter than this are discarded.")

                platformSlider("Attack Debounce", key: "stt_attack_debounce_ms", range: 0...600, step: 100, unit: " ms")
                hintText("How long a sound must be sustained before speech is detected. Filters sharp transients like claps or door slams.")

                if sttProvider == "openai" {
                    platformSlider("No-Speech Filter", key: "stt_no_speech_threshold", range: 0.1...0.9, step: 0.05, unit: "", format: "%.2f")
                    hintText("Whisper segments with no-speech probability above this are filtered.")
                }

                savePlatformButton
                    .padding(.top, 20)
            }
            .padding(16)
        }
    }

    // MARK: - Reusable Components

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(theme.labelFont(size: 17))
            .tracking(1)
            .foregroundStyle(theme.textQuaternary)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label)
            .font(theme.bodyFont(size: 18))
            .foregroundStyle(theme.textQuaternary)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(theme.monoFont(size: 17))
            .foregroundStyle(theme.textQuinary)
            .padding(.top, 2)
            .padding(.bottom, 8)
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.elevated)
            .frame(height: theme.borderWidth)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private func formTextField(_ key: String, placeholder: String = "", secure: Bool = false, disabled: Bool = false) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: formBinding(key))
            } else {
                TextField(placeholder, text: formBinding(key))
            }
        }
        .font(theme.bodyFont(size: 21))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func platformTextField(_ key: String, placeholder: String = "", secure: Bool = false) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: platformBinding(key))
            } else {
                TextField(placeholder, text: platformBinding(key))
            }
        }
        .font(theme.bodyFont(size: 21))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func providerPicker(_ key: String, options: [(String, String)]) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { vm.form[key] = option.0; Task { await vm.fetchTtsModels(); await vm.fetchVoices() } }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == vm.form[key] }?.1 ?? vm.form[key] ?? "")
                    .font(theme.bodyFont(size: 21))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(theme.bodyFont(size: 18))
                    .foregroundStyle(theme.textQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }

    private func pickerMenu(_ key: String, options: [(String, String)]) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) {
                    vm.form[key] = option.0
                    if key == "model_id" { Task { await vm.fetchVoices() } }
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == vm.form[key] }?.1 ?? vm.form[key] ?? "")
                    .font(theme.bodyFont(size: 21))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(theme.bodyFont(size: 18))
                    .foregroundStyle(theme.textQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }

    private func pickerMenuPlatform(_ key: String, options: [(String, String)]) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { vm.platformForm[key] = option.0 }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == vm.platformForm[key] }?.1 ?? vm.platformForm[key] ?? "")
                    .font(theme.bodyFont(size: 21))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(theme.bodyFont(size: 18))
                    .foregroundStyle(theme.textQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }

    private func sliderField(_ label: String, key: String, range: ClosedRange<Double>, step: Double, format: String = "%.0f") -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(theme.bodyFont(size: 18))
                    .foregroundStyle(theme.textQuaternary)
                Spacer()
                Text(String(format: format, Double(vm.form[key] ?? "0") ?? 0))
                    .font(theme.monoFont(size: 18))
                    .foregroundStyle(theme.textQuaternary)
            }
            .padding(.top, 8)

            Slider(value: Binding(
                get: { Double(vm.form[key] ?? "0") ?? range.lowerBound },
                set: { vm.form[key] = String($0) }
            ), in: range, step: step)
            .tint(theme.primary)
        }
    }

    private func platformSlider(_ label: String, key: String, range: ClosedRange<Double>, step: Double, unit: String, format: String = "%.0f") -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(theme.bodyFont(size: 18))
                    .foregroundStyle(theme.textQuaternary)
                Spacer()
                Text("\(String(format: format, Double(vm.platformForm[key] ?? "0") ?? 0))\(unit)")
                    .font(theme.monoFont(size: 18))
                    .foregroundStyle(theme.textQuaternary)
            }
            .padding(.top, 8)

            Slider(value: Binding(
                get: { Double(vm.platformForm[key] ?? "0") ?? range.lowerBound },
                set: { vm.platformForm[key] = String($0) }
            ), in: range, step: step)
            .tint(theme.primary)
        }
    }

    private var savePlatformButton: some View {
        Button(action: {
            Task {
                do {
                    try await vm.savePlatformSettings()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }) {
            Text(vm.isSavingPlatform ? "Saving..." : "Save Settings")
                .font(theme.bodyFont(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(theme.primary)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .disabled(vm.isSavingPlatform)
        .opacity(vm.isSavingPlatform ? 0.5 : 1)
    }

    // MARK: - Account Tab

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let themeManager {
                    sectionTitle("SKIN")
                    HStack {
                        ForEach(ThemeName.allCases, id: \.rawValue) { name in
                            Button {
                                themeManager.currentName = name
                            } label: {
                                Text(name.displayName)
                                    .font(theme.bodyFont(size: 21, weight: themeManager.currentName == name ? .semibold : .regular))
                                    .foregroundStyle(themeManager.currentName == name ? theme.textPrimary : theme.textTertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .background(themeManager.currentName == name ? theme.border : theme.elevated)
                                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    sectionTitle("CHAT TEXT SIZE")
                    HStack(spacing: 12) {
                        Text("A")
                            .font(theme.bodyFont(size: 18))
                            .foregroundStyle(theme.textQuaternary)
                        Slider(
                            value: Binding(
                                get: { themeManager.chatFontSize },
                                set: { themeManager.chatFontSize = $0 }
                            ),
                            in: 12...24,
                            step: 1
                        )
                        .tint(theme.primary)
                        Text("A")
                            .font(theme.bodyFont(size: 36))
                            .foregroundStyle(theme.textQuaternary)
                    }

                    // Preview
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preview")
                            .font(theme.monoFont(size: 17))
                            .foregroundStyle(theme.textQuaternary)
                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(theme.bodyFont(size: themeManager.chatFontSize))
                            .foregroundStyle(theme.textSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Account Tab

    private var accountTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let account = AccountStore.shared.currentAccount

                sectionTitle("SERVER")
                Text(account?.serverURL ?? AppConfig.serverBase)
                    .font(theme.bodyFont(size: 21))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

                sectionTitle("USERNAME")
                Text(account?.username ?? "—")
                    .font(theme.bodyFont(size: 21))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

                Button(action: {
                    AccountStore.shared.clearCurrentAccount()
                    authService.logout()
                    dismiss()
                }) {
                    Text("Sign Out")
                        .font(theme.bodyFont(size: 21, weight: .semibold))
                        .foregroundStyle(theme.error)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(theme.border)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                .padding(.top, 24)
            }
            .padding(16)
        }
    }

    // MARK: - Helpers

    private func hasUnsavedChanges() -> Bool {
        switch vm.selectedTab {
        case .agents: return vm.isAgentFormDirty
        case .tts, .stt: return vm.isPlatformFormDirty
        case .appearance, .account: return false
        }
    }

    private func attemptAction(action: @escaping () -> Void) {
        if hasUnsavedChanges() {
            pendingAction = action
            showUnsavedAlert = true
        } else {
            action()
        }
    }

    private func formBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { vm.form[key] ?? "" },
            set: { vm.form[key] = $0 }
        )
    }

    private func platformBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { vm.platformForm[key] ?? "" },
            set: { vm.platformForm[key] = $0 }
        )
    }

    private func statusColor(_ status: Agent.AgentStatus) -> Color {
        switch status {
        case .healthy: theme.success
        case .error: theme.error
        case .unknown: theme.primary
        }
    }
}
