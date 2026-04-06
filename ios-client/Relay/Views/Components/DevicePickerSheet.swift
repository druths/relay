import SwiftUI
import AVFoundation

struct DevicePickerSheet: View {
    let title: String
    let onSelect: (AVAudioSessionPortDescription) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme
    @State private var inputs: [AVAudioSessionPortDescription] = []
    @State private var currentUid: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if inputs.isEmpty {
                    Text("No devices available")
                        .foregroundStyle(theme.textQuaternary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(inputs, id: \.uid) { input in
                        Button(action: {
                            onSelect(input)
                            dismiss()
                        }) {
                            HStack {
                                Text(input.portName)
                                    .foregroundStyle(theme.textSecondary)
                                Spacer()
                                if input.uid == currentUid {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(theme.success)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            let session = AVAudioSession.sharedInstance()
            inputs = session.availableInputs ?? []
            currentUid = session.currentRoute.inputs.first?.uid
            isLoading = false
        }
    }
}
