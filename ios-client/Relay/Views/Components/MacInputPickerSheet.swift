#if targetEnvironment(macCatalyst)
import SwiftUI
import CoreAudio

/// Catalyst-only input-device picker. Enumerates via CoreAudio (not
/// AVAudioSession, which hides most USB / aggregate / virtual
/// devices on Mac Catalyst) and switches the **system default
/// input** when the user picks one.
///
/// Note that this also changes the input other Mac apps use (Zoom,
/// Meet, Voice Memos). The alternative — binding Relay's engine
/// directly to a device via `kAudioOutputUnitProperty_CurrentDevice`
/// — conflicts with the voice-processing AU we rely on for echo
/// cancellation; see `MacAudioDevices` doc comment.
struct MacInputPickerSheet: View {
    let audio: AudioViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme

    @State private var devices: [MacAudioDevices.Device] = []
    @State private var selectedID: AudioDeviceID?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if devices.isEmpty {
                    Text("No input devices found")
                        .foregroundStyle(theme.textQuaternary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(devices) { device in
                        Button(action: { select(device) }) {
                            HStack {
                                Text(device.name)
                                    .foregroundStyle(theme.textSecondary)
                                Spacer()
                                if device.id == selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(theme.success)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Input Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .task { refresh() }
    }

    private func refresh() {
        devices = MacAudioDevices.inputs()
        selectedID = MacAudioDevices.systemDefaultInputID()
        isLoading = false
    }

    private func select(_ device: MacAudioDevices.Device) {
        audio.setMacInputDevice(device)
        selectedID = device.id
        dismiss()
    }
}
#endif
