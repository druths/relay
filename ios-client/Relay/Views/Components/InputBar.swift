import SwiftUI

struct InputBar: View {
    @Bindable var relay: RelayViewModel
    @State private var text = ""
    @State private var showInputPicker = false
    @State private var showOutputPicker = false

    private var recorderState: AudioRecorderService.State {
        relay.audio.recorderState
    }

    private var disabled: Bool {
        !relay.connected
    }

    var body: some View {
        HStack(spacing: 6) {
            if relay.isLiveMode {
                liveContent
            } else {
                chatContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.relaySurface
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.relayBorder)
                        .frame(height: 1)
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

        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.relayTextQuaternary))
            .textFieldStyle(RelayInputFieldStyle(isDisabled: disabled))
            .disabled(disabled)
            .onSubmit { handleSend() }

        Button(action: handleSend) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(sendButtonEnabled ? Color.relayPrimary : Color.relayBorder)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!sendButtonEnabled)
    }

    // MARK: - Live Mode

    @ViewBuilder
    private var liveContent: some View {
        SoundWaveView(meteringLevel: relay.audio.meteringLevel)
            .frame(maxWidth: .infinity)

        muteButton

        Button(action: { relay.exitLiveMode() }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.relayError)
                .frame(width: 36, height: 36)
                .background(Color.relayError.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Subviews

    private var goLiveButton: some View {
        Button(action: handleGoLive) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.relaySuccess)
                .frame(width: 36, height: 36)
                .background(Color.relaySuccess.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
            Image(systemName: relay.audio.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 14))
                .foregroundStyle(relay.audio.isMuted ? Color.relayError : Color.relayTextTertiary)
                .frame(width: 36, height: 36)
                .background(relay.audio.isMuted ? Color.relayMutedButton : Color.relayElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
    let isDisabled: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.relayElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(Color.relayTextSecondary)
            .font(.system(size: 14))
            .opacity(isDisabled ? 0.5 : 1)
    }
}

// MARK: - Output mode picker sheet

struct OutputPickerSheet: View {
    let currentMode: RelayViewModel.OutputMode
    let onSelect: (RelayViewModel.OutputMode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button(action: { onSelect(.speaker); dismiss() }) {
                    HStack {
                        Text("Speaker")
                        Spacer()
                        if currentMode == .speaker {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.relaySuccess)
                        }
                    }
                }

                Button(action: { onSelect(.earpiece); dismiss() }) {
                    HStack {
                        Text("Earpiece")
                        Spacer()
                        if currentMode == .earpiece {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.relaySuccess)
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
