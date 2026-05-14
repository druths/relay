import SwiftUI
import UniformTypeIdentifiers

struct InputBar: View {
    @Bindable var relay: RelayViewModel
    var externalFocus: FocusState<Bool>.Binding? = nil
    @Environment(\.relayTheme) private var theme
    @State private var text = ""
    @State private var showInputPicker = false
    @State private var showOutputPicker = false
    @State private var showFilePicker = false
    @State private var isUploading = false
    @FocusState private var localFocus: Bool

    private var recorderState: AudioRecorderService.State {
        relay.audio.recorderState
    }

    private var disabled: Bool {
        !relay.connected
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
            DevicePickerSheet(
                title: "Input Device",
                onSelect: { port in
                    relay.audio.setPreferredInput(port)
                }
            )
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

        if relay.activeSessionId != nil {
            attachButton
        }

        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textQuaternary), axis: .vertical)
            .textFieldStyle(RelayInputFieldStyle(isDisabled: disabled))
            .lineLimit(1...6)
            .disabled(disabled)
            .focused(externalFocus ?? $localFocus)
            .onSubmit { handleSend() }

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

    private var attachButton: some View {
        Button {
            showFilePicker = true
        } label: {
            Image(systemName: "paperclip")
                .font(theme.bodyFont(size: 18, weight: .semibold))
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
                _ = await relay.uploadAttachment(
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
        !disabled && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await relay.sendMessage(trimmed) }
        text = ""
    }

    private func handleGoLive() {
        guard !disabled else { return }
        relay.enterLiveMode()
    }
}

// MARK: - Input text field style

struct RelayInputFieldStyle: TextFieldStyle {
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayChatFontSize) private var chatFontSize
    let isDisabled: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .foregroundStyle(theme.textSecondary)
            .font(theme.bodyFont(size: chatFontSize))
            .opacity(isDisabled ? 0.5 : 1)
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
