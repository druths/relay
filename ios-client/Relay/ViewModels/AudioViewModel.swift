import AVFoundation

@Observable
@MainActor
final class AudioViewModel {
    var recorderState: AudioRecorderService.State = .idle
    var meteringLevel: Float = -160

    let recorder = AudioRecorderService()
    let player = AudioPlayerService()

    private var previousSessionId: String?

    func setup(onRecordingComplete: @escaping @Sendable (String, String, URL) async -> Void) {
        let player = self.player
        Task {
            await recorder.set(onRecordingComplete: onRecordingComplete)
            await recorder.set(onStateChange: { [weak self] state in
                await MainActor.run {
                    self?.recorderState = state
                }
                // Stop TTS playback when user starts speaking
                if state == .recording {
                    await player.stop()
                }
            })
            await recorder.set(onMeteringUpdate: { [weak self] level in
                await MainActor.run {
                    self?.meteringLevel = level
                }
            })
        }
    }

    func startListening() {
        Task { await recorder.startListening() }
    }

    func stopListening() {
        Task { await recorder.stopListening() }
    }

    func stopAudio() {
        Task { await player.stop() }
    }

    var isMuted: Bool {
        get {
            // Workaround: can't access actor synchronously, so track locally
            _isMuted
        }
        set {
            _isMuted = newValue
            Task { await recorder.setMuted(newValue) }
        }
    }
    private var _isMuted = false

    func handleSessionChange(newSessionId: String?) {
        let oldSessionId = previousSessionId
        previousSessionId = newSessionId

        guard oldSessionId != newSessionId else { return }

        // Don't stop+start the recorder on session transitions — it briefly reconfigures the
        // audio session to .playback (via cleanup), which clips the agent's first audio chunk.
        // The recorder keeps running through session changes; VAD state is irrelevant here.
        print("[STT][session] handleSessionChange: \(oldSessionId ?? "nil") → \(newSessionId ?? "nil") (recorder continues)")
    }

    func updateSettings(silenceThresholdDb: Float, silenceTimeoutMs: Int, minDurationMs: Int) {
        Task {
            await recorder.set(silenceThresholdDb: silenceThresholdDb)
            await recorder.set(silenceTimeoutMs: silenceTimeoutMs)
            await recorder.set(minDurationMs: minDurationMs)
        }
    }

    func setEarpieceMode(_ enabled: Bool) {
        Task { await recorder.set(earpieceMode: enabled) }
    }

    func getAvailableInputs() async -> [AVAudioSessionPortDescription] {
        await recorder.getAvailableInputs()
    }

    func getCurrentInput() async -> AVAudioSessionPortDescription? {
        await recorder.getCurrentInput()
    }

    func setPreferredInput(_ port: AVAudioSessionPortDescription) {
        Task { await recorder.setPreferredInput(port) }
    }
}

// Extension to set properties on the actor
extension AudioRecorderService {
    func set(onRecordingComplete: @escaping @Sendable (String, String, URL) async -> Void) {
        self.onRecordingComplete = onRecordingComplete
    }

    func set(onStateChange: @escaping @Sendable (State) async -> Void) {
        self.onStateChange = onStateChange
    }

    func set(silenceThresholdDb: Float) {
        self.silenceThresholdDb = silenceThresholdDb
    }

    func set(silenceTimeoutMs: Int) {
        self.silenceTimeoutMs = silenceTimeoutMs
    }

    func set(minDurationMs: Int) {
        self.minDurationMs = minDurationMs
    }

    func set(earpieceMode: Bool) {
        self.earpieceMode = earpieceMode
    }

    func set(onMeteringUpdate: @escaping @Sendable (Float) async -> Void) {
        self.onMeteringUpdate = onMeteringUpdate
    }
}
