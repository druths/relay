import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct InputBar: View {
    @Bindable var relay: RelayViewModel
    /// Optional binding into a viewmodel-level focus flag. Falls back to
    /// a private local state when not provided. The wrapper mirrors
    /// first-responder state both ways through it.
    var messageFocus: Binding<Bool>? = nil
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayChatFontSize) private var chatFontSize
    /// Read-back surface into the UIKit-backed message field.
    @State private var handle = ChatMessageFieldHandle()
    /// Trimmed-non-empty state of the buffer. Driven by the field's
    /// edge callback so we don't burn a SwiftUI re-render per keystroke
    /// just to disable/enable the send button.
    @State private var hasContent = false
    /// Bumped after each successful send to clear the field.
    @State private var clearTrigger = 0
    /// Line-bounded preferred height the field reports as the user
    /// types. Initially a one-line estimate that the field corrects on
    /// first layout via `onPreferredHeightChange`.
    @State private var fieldHeight: CGFloat = 22
    @State private var showInputPicker = false
    @State private var showOutputPicker = false
    @State private var showFilePicker = false
    @State private var showCameraPicker = false
    @State private var showPhotoPicker = false
    @State private var isUploading = false
    /// Fallback focus state when no viewmodel-level binding is provided.
    @State private var localFocus = false
    /// Mac-only: name of the current audio input, refreshed on route
    /// changes so the inline picker label stays accurate as the
    /// machine moves between docks, Bluetooth headsets, etc.
    @State private var macCurrentInputName: String = "Default"

    private var recorderState: AudioRecorderService.State {
        relay.audio.recorderState
    }

    private var disabled: Bool {
        if !relay.connected { return true }
        // Refuse input while ark is compacting the active session — sending
        // a message mid-compaction would race the summarizer.
        if let sid = relay.activeSessionId, relay.compacting[sid] != nil {
            return true
        }
        return false
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if relay.isLiveMode {
                liveContent
            } else {
                chatContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            theme.surface
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: theme.borderWidth)
                }
        )
        .animation(.easeInOut(duration: 0.25), value: relay.isLiveMode)
        .sheet(isPresented: $showInputPicker) {
            #if targetEnvironment(macCatalyst)
            // Catalyst gets the CoreAudio-backed picker so USB /
            // aggregate / virtual devices actually show up, and the
            // selection binds the engine per-app rather than
            // swapping the system default.
            MacInputPickerSheet(audio: relay.audio)
            #else
            DevicePickerSheet(
                title: "Input Device",
                onSelect: { port in
                    relay.audio.setPreferredInput(port)
                }
            )
            #endif
        }
        .sheet(isPresented: $showOutputPicker) {
            OutputPickerSheet(
                currentMode: relay.outputMode,
                onSelect: { mode in
                    relay.setOutputMode(mode)
                }
            )
        }
    }

    // MARK: - Chat Mode

    @ViewBuilder
    private var chatContent: some View {
        goLiveButton

        // Attach menu is always visible in chat mode — lobby or
        // session — so the + is a stable fixture of the input bar.
        // Uploads in the lobby ride on the same chat-attachment
        // path and surface to whichever agent the user ends up
        // routed into.
        attachButton

        ChatMessageField(
            handle: handle,
            placeholder: placeholder,
            font: uiBodyFont,
            textColor: UIColor(theme.textSecondary),
            placeholderColor: UIColor(theme.textQuaternary),
            focused: messageFocus ?? $localFocus,
            onHasContentChange: { hasContent = $0 },
            onSubmit: { handleSend() },
            onPreferredHeightChange: { fieldHeight = $0 },
            clearTrigger: clearTrigger,
        )
        .frame(maxWidth: .infinity)
        .frame(height: fieldHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)

        if isTurnInFlight, let sid = relay.activeSessionId {
            Button(action: { Task { await relay.stopSession(sid) } }) {
                ThemedIcon(systemName: "stop.fill")
                    .font(theme.bodyFont(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(theme.error)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            }
        } else {
            Button(action: handleSend) {
                ThemedIcon(systemName: "paperplane.fill")
                    .font(theme.bodyFont(size: 18, weight: .semibold))
                    .foregroundStyle(theme.sendButtonInverted ? theme.background : .white)
                    .frame(width: 44, height: 44)
                    .background(sendButtonEnabled ? theme.primary : theme.border)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            }
            .disabled(!sendButtonEnabled)
        }
    }

    /// True while an ark turn is streaming on the active session. Signal
    /// is the last message being an in-flight streaming agent bubble —
    /// mirrors what the user sees (thinking dots) so the Stop button
    /// appears exactly when there's actually something to stop.
    private var isTurnInFlight: Bool {
        guard relay.activeSessionId != nil,
              let last = relay.sessionMessages.last,
              last.isStreaming else { return false }
        // Stop is ark-only for now; direct-provider paths don't have
        // an equivalent cancellation primitive on the Relay side.
        guard let sess = relay.sessions.first(where: { $0.sessionId == relay.activeSessionId }),
              let agent = relay.agents.first(where: { $0.agentId == sess.agentId }),
              agent.llmProvider == "ark" else { return false }
        return true
    }

    /// Attach menu — a `+` button that opens Photos / Camera /
    /// Files. On Mac Catalyst the camera + photo-library options
    /// aren't meaningful (no camera; no Photos library picker), so
    /// the menu collapses to just Files there.
    private var attachButton: some View {
        Menu {
            #if !targetEnvironment(macCatalyst)
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                showCameraPicker = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
            #endif
            Button {
                showFilePicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(theme.bodyFont(size: 20, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(theme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .opacity(isUploading ? 0.5 : 1.0)
        }
        .disabled(disabled || isUploading)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
        ) { result in
            switch result {
            case .success(let urls):
                Task { await handleFiles(urls) }
            case .failure(let err):
                print("[Relay] File picker error: \(err)")
            }
        }
        #if !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showCameraPicker) {
            CameraPicker { data, filename in
                Task { await uploadInMemoryBatch([(data, filename, "image/jpeg")]) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker(selectionLimit: 10) { picks in
                let batch = picks.map { ($0.data, $0.filename, "image/jpeg") }
                Task { await uploadInMemoryBatch(batch) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    /// Common upload path for the Camera / Photos results — the data
    /// is already in memory (no security-scoped URL to dance with),
    /// so we skip `handleFiles`' file-reading preamble and feed the
    /// bytes straight into the shared upload registry.
    private func uploadInMemoryBatch(
        _ items: [(data: Data, filename: String, mime: String)],
    ) async {
        guard !items.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }
        for item in items {
            _ = await relay.uploadChatAttachment(
                data: item.data,
                filename: item.filename,
                mimeType: item.mime,
            )
        }
    }

    private func handleFiles(_ urls: [URL]) async {
        isUploading = true
        defer { isUploading = false }
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                    ?? "application/octet-stream"
                // Progress-aware version — feeds the shared uploads
                // registry rendered by UploadStrip above the input bar.
                _ = await relay.uploadChatAttachment(
                    data: data,
                    filename: url.lastPathComponent,
                    mimeType: mime,
                )
            } catch {
                print("[Relay] Failed to read picked file \(url.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Live Mode

    @ViewBuilder
    private var liveContent: some View {
        SoundWaveView(meteringLevel: relay.audio.meteringLevel)
            .frame(maxWidth: .infinity)

        #if targetEnvironment(macCatalyst)
        // Mac laptops roam between configurations (built-in mic,
        // USB headset, Bluetooth earbuds, external mic). On iOS
        // AVAudioSession routes implicitly; on Mac the user expects
        // to pick, so expose an input picker inline while live mode
        // is on. Output stays on the system default — the macOS
        // Sound-preferences shortcut button was a weird UX and the
        // Mac convention is already "set it in Sound settings".
        macInputButton
        #endif

        muteButton

        Button(action: { relay.exitLiveMode() }) {
            ThemedIcon(systemName: "xmark.circle.fill")
                .font(theme.bodyFont(size: 18, weight: .semibold))
                .foregroundStyle(theme.error)
                .frame(width: 44, height: 44)
                .background(theme.error.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Mac-only inline input-device picker. Shows the current
    /// system default input and opens `MacInputPickerSheet` (which
    /// enumerates via CoreAudio and sets the system default) on
    /// click.
    private var macInputButton: some View {
        Button(action: { showInputPicker = true }) {
            HStack(spacing: 6) {
                ThemedIcon(systemName: "mic.fill")
                    .font(theme.bodyFont(size: 14, weight: .semibold))
                Text(macCurrentInputName)
                    .font(theme.bodyFont(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                ThemedIcon(systemName: "chevron.down")
                    .font(theme.bodyFont(size: 10, weight: .semibold))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .frame(maxWidth: 180)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .help("Choose input device")
        .task { refreshMacInputName() }
        // Poll the system default on sheet dismissal so the label
        // picks up a selection the user just made. The CoreAudio
        // notification path is noisier than it's worth here.
        .onChange(of: showInputPicker) { _, open in
            if !open { refreshMacInputName() }
        }
    }

    private func refreshMacInputName() {
        if let id = MacAudioDevices.systemDefaultInputID(),
           let dev = MacAudioDevices.inputs().first(where: { $0.id == id }) {
            macCurrentInputName = dev.name
            return
        }
        macCurrentInputName = "Default"
    }
    #endif

    // MARK: - Subviews

    private var goLiveButton: some View {
        Button(action: handleGoLive) {
            ThemedIcon(systemName: "waveform")
                .font(theme.bodyFont(size: 18, weight: .bold))
                .foregroundStyle(theme.liveButtonInverted ? theme.primary : theme.success)
                .frame(width: 44, height: 44)
                .background(theme.liveButtonInverted ? theme.background : theme.success.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(
                    theme.liveButtonInverted
                        ? RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .stroke(theme.primary.opacity(0.5), lineWidth: theme.borderWidth)
                        : nil
                )
        }
        .disabled(disabled)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    HapticService.impact(.medium)
                    showInputPicker = true
                }
        )
    }

    private var muteButton: some View {
        Button(action: { relay.toggleMute() }) {
            ThemedIcon(systemName: relay.audio.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(theme.bodyFont(size: 18, weight: .semibold))
                .foregroundStyle(relay.audio.isMuted ? theme.error : theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(relay.audio.isMuted ? theme.mutedButton : theme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    HapticService.impact(.medium)
                    showOutputPicker = true
                }
        )
    }

    // MARK: - Computed

    private var placeholder: String {
        disabled ? "Connect to start..." : "Type a message..."
    }

    private var sendButtonEnabled: Bool {
        !disabled && hasContent
    }

    /// UIFont version of the active theme's body font at the user's
    /// chosen chat font size. Falls back to the system font when the
    /// theme's custom font isn't loadable for any reason.
    private var uiBodyFont: UIFont {
        if let name = theme.bodyFontName, let f = UIFont(name: name, size: chatFontSize) {
            return f
        }
        return .systemFont(ofSize: chatFontSize)
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = handle.currentText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await relay.sendMessage(trimmed) }
        clearTrigger &+= 1
        hasContent = false
        // Snap the row back to one line immediately. The wrapper-driven
        // height update through `onPreferredHeightChange` is unreliable
        // here — the closure fires inside `updateUIView` during a
        // SwiftUI layout pass, and the resulting `@State` write can be
        // deferred long enough that the field appears "stuck" at the
        // multi-line height the user just sent from.
        fieldHeight = handle.oneLineHeight
    }

    private func handleGoLive() {
        guard !disabled else { return }
        relay.enterLiveMode()
    }
}

// MARK: - Output mode picker sheet

struct OutputPickerSheet: View {
    let currentMode: RelayViewModel.OutputMode
    let onSelect: (RelayViewModel.OutputMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme

    var body: some View {
        NavigationStack {
            List {
                Button(action: { onSelect(.speaker); dismiss() }) {
                    HStack {
                        Text("Speaker")
                        Spacer()
                        if currentMode == .speaker {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.success)
                        }
                    }
                }

                Button(action: { onSelect(.earpiece); dismiss() }) {
                    HStack {
                        Text("Earpiece")
                        Spacer()
                        if currentMode == .earpiece {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.success)
                        }
                    }
                }
            }
            .navigationTitle("Output Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
