import SwiftUI

struct AgentManagementView: View {
    let agents: [Agent]
    let authService: AuthService
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vm: AgentManagementViewModel
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    init(agents: [Agent], authService: AuthService, onChanged: @escaping () -> Void) {
        self.agents = agents
        self.authService = authService
        self.onChanged = onChanged
        _vm = State(initialValue: AgentManagementViewModel(apiClient: APIClient(authService: authService)))
    }

    private var sortedAgents: [Agent] {
        agents.sorted {
            if $0.isOperator { return true }
            if $1.isOperator { return false }
            return $0.name < $1.name
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                tabContent
            }
            .background(Color.relaySurface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            await vm.loadPlatformSettings()
            if let first = sortedAgents.first {
                vm.selectAgent(first)
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(AgentManagementViewModel.Tab.allCases, id: \.self) { tab in
                Button(action: { vm.selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(vm.selectedTab == tab ? Color.relayTextPrimary : Color.relayTextQuaternary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(vm.selectedTab == tab ? Color.relayBorder : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.relayElevated).frame(height: 1)
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
                Rectangle().fill(Color.relayElevated).frame(height: 1)
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

    private func agentPill(_ agent: Agent) -> some View {
        let isActive = !vm.isNewAgent && vm.selectedAgentId == agent.agentId
        return Button(action: { vm.selectAgent(agent); Task { await vm.fetchVoices() } }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(agent.status))
                    .frame(width: 8, height: 8)
                if agent.isOperator {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.relayTextQuaternary)
                }
                Text(agent.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Color.relayTextPrimary : Color.relayTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Color.relayBorder : Color.relayElevated)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var newAgentPill: some View {
        Button(action: { vm.startNewAgent() }) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                Text("New")
                    .font(.system(size: 13))
            }
            .foregroundStyle(vm.isNewAgent ? Color.relayPrimaryLighter : Color.relayPrimaryLight)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(vm.isNewAgent ? Color.relayNewAgentPill : Color.relayElevated)
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
                Circle()
                    .fill(statusColor(selected.status))
                    .frame(width: 8, height: 8)
                Text(selected.status == .healthy ? "Healthy" : selected.status == .error ? (selected.statusMessage.isEmpty ? "Error" : selected.statusMessage) : "Unknown")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextTertiary)
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
                        .font(.system(size: 14))
                        .foregroundStyle(Color.relayTextSecondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.relayTextQuaternary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Color.relayElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(vm.voices.isEmpty)
            .opacity(vm.voices.isEmpty ? 0.5 : 1)
        }

        // OpenAI voice settings
        if ttsProvider == "openai" {
            sectionLabel("Model")
            pickerMenu("model", options: [("tts-1", "tts-1"), ("tts-1-hd", "tts-1-hd")])

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
        .font(.system(size: 14))
        .foregroundStyle(Color.relayTextSecondary)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 80)
        .padding(8)
        .background(Color.relayElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))

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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.relayPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(vm.isSaving)
            .opacity(vm.isSaving ? 0.5 : 1)

            if let selected, !selected.isOperator {
                Button(action: { showDeleteConfirm = true }) {
                    Text("Delete")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.relayError)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.relayBorder)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            .font(.system(size: 11, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Color.relayTextQuaternary)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12))
            .foregroundStyle(Color.relayTextQuaternary)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.relayTextQuinary)
            .padding(.top, 2)
            .padding(.bottom, 8)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.relayElevated)
            .frame(height: 1)
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
        .font(.system(size: 14))
        .foregroundStyle(Color.relayTextSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.relayElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        .font(.system(size: 14))
        .foregroundStyle(Color.relayTextSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.relayElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func providerPicker(_ key: String, options: [(String, String)]) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { vm.form[key] = option.0; Task { await vm.fetchVoices() } }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == vm.form[key] }?.1 ?? vm.form[key] ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.relayTextSecondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.relayElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func pickerMenu(_ key: String, options: [(String, String)]) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { vm.form[key] = option.0 }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == vm.form[key] }?.1 ?? vm.form[key] ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.relayTextSecondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.relayElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
                    .font(.system(size: 14))
                    .foregroundStyle(Color.relayTextSecondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.relayElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sliderField(_ label: String, key: String, range: ClosedRange<Double>, step: Double, format: String = "%.0f") -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextQuaternary)
                Spacer()
                Text(String(format: format, Double(vm.form[key] ?? "0") ?? 0))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextQuaternary)
            }
            .padding(.top, 8)

            Slider(value: Binding(
                get: { Double(vm.form[key] ?? "0") ?? range.lowerBound },
                set: { vm.form[key] = String($0) }
            ), in: range, step: step)
            .tint(Color.relayPrimary)
        }
    }

    private func platformSlider(_ label: String, key: String, range: ClosedRange<Double>, step: Double, unit: String, format: String = "%.0f") -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextQuaternary)
                Spacer()
                Text("\(String(format: format, Double(vm.platformForm[key] ?? "0") ?? 0))\(unit)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextQuaternary)
            }
            .padding(.top, 8)

            Slider(value: Binding(
                get: { Double(vm.platformForm[key] ?? "0") ?? range.lowerBound },
                set: { vm.platformForm[key] = String($0) }
            ), in: range, step: step)
            .tint(Color.relayPrimary)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.relayPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(vm.isSavingPlatform)
        .opacity(vm.isSavingPlatform ? 0.5 : 1)
    }

    // MARK: - Helpers

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
        case .healthy: Color.relaySuccess
        case .error: Color.relayError
        case .unknown: Color.relayTextQuaternary
        }
    }
}
