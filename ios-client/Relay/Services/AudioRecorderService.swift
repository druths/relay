import AVFoundation

/// VAD-based audio recorder with silence detection, dead-input recovery, and continuous mode.
/// Ported from mobile/src/hooks/useAudioRecorder.ts.
actor AudioRecorderService {
    enum State: Sendable, Equatable {
        case idle, listening, recording, processing
    }

    // MARK: - Public state

    private(set) var state: State = .idle

    // MARK: - Configuration

    var silenceThresholdDb: Float = -35
    var silenceTimeoutMs: Int = 1500
    var minDurationMs: Int = 400
    var earpieceMode: Bool = false

    // MARK: - Callbacks

    var onRecordingComplete: (@Sendable (String, String, URL) async -> Void)?
    var onStateChange: (@Sendable (State) async -> Void)?
    var onMeteringUpdate: (@Sendable (Float) async -> Void)?

    // MARK: - Metering

    private(set) var currentMeteringLevel: Float = -160

    // MARK: - Internal state

    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?
    private var isActive = false
    private var isStopping = false
    private var speechDetected = false
    private var silenceStart: ContinuousClock.Instant?
    private var recordStart: ContinuousClock.Instant?
    private var preferredInput: AVAudioSessionPortDescription?
    private var meteringTick = 0
    private var deadInputTicks = 0

    private let deadInputThreshold: Float = -100
    private let deadInputTickLimit = 5

    // MARK: - Public API

    func startListening() async {
        print("[STT][lifecycle] startListening called")
        await cleanup()

        // Request microphone permission
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        }

        guard granted else {
            print("[STT] Microphone permission denied")
            return
        }

        // Tear down any stale recorder/session before starting fresh
        if recorder != nil {
            recorder?.stop()
            recorder = nil
            stopMeteringPoll()
        }

        // Deactivate first to clear stale audio hardware references, then
        // wait briefly for the simulator's audio hardware to settle
        AudioSessionManager.deactivate()
        try? await Task.sleep(for: .milliseconds(100))

        do {
            try AudioSessionManager.configure(earpieceMode ? .earpiece : .playAndRecord)
        } catch {
            print("[STT] Failed to configure audio session: \(error)")
            return
        }

        isActive = true
        isStopping = false
        isContinuousRestart = true  // session already configured above

        print("[STT][lifecycle] startListening → startNewRecording")
        await startNewRecording()
    }

    func stopListening() async {
        print("[STT][lifecycle] stopListening called (speech=\(speechDetected), recorder=\(recorder != nil))")
        isStopping = true
        isActive = false
        stopMeteringPoll()

        if let recorder {
            if speechDetected {
                print("[STT][lifecycle] stopListening: has speech → processRecording")
                await processRecording(recorder)
            } else {
                print("[STT][lifecycle] stopListening: no speech → cleanup")
                await cleanup()
            }
        } else {
            print("[STT][lifecycle] stopListening: no recorder → cleanup")
            await cleanup()
        }
    }

    func setPreferredInput(_ port: AVAudioSessionPortDescription) {
        preferredInput = port
        try? AVAudioSession.sharedInstance().setPreferredInput(port)
    }

    func setMuted(_ muted: Bool) {
        if muted {
            // Pause recording — stop the recorder but stay in listening mode
            stopMeteringPoll()
            if let recorder, recorder.isRecording {
                recorder.pause()
            }
            currentMeteringLevel = -160
            Task { await onMeteringUpdate?(-160) }
            print("[STT] mic muted")
        } else {
            // Resume recording
            if let recorder {
                recorder.record()
                startMeteringPoll()
            }
            print("[STT] mic unmuted")
        }
    }

    func getAvailableInputs() -> [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    func getCurrentInput() -> AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first
    }

    // MARK: - Private

    private var isContinuousRestart = false

    private func startNewRecording() async {
        print("[STT][lifecycle] startNewRecording called (active=\(isActive), continuous=\(isContinuousRestart))")
        guard isActive else {
            print("[STT][lifecycle] startNewRecording: bailing — not active")
            return
        }

        speechDetected = false
        silenceStart = nil
        meteringTick = 0
        deadInputTicks = 0
        currentMeteringLevel = -160
        await setState(.listening)

        do {
            // Only reconfigure audio session on first start, not continuous restarts
            if !isContinuousRestart {
                try AudioSessionManager.configure(earpieceMode ? .earpiece : .playAndRecord)
            }
            isContinuousRestart = false

            if let preferred = preferredInput {
                try? AVAudioSession.sharedInstance().setPreferredInput(preferred)
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay_recording_\(UUID().uuidString).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]

            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.isMeteringEnabled = true
            newRecorder.prepareToRecord()
            newRecorder.record()

            recorder = newRecorder
            print("[STT][lifecycle] recorder started — now polling metering")

            // Start silent keepalive after recorder to avoid I/O conflict
            await SilentKeepAlive.shared.start()

            startMeteringPoll()
        } catch {
            print("[STT] Failed to start recording: \(error)")
            await cleanup()
        }
    }

    private func processRecording(_ rec: AVAudioRecorder) async {
        let duration = recordStart.map { ContinuousClock.now - $0 } ?? .zero
        let durationMs = Int(duration.components.seconds * 1000 + Int64(duration.components.attoseconds / 1_000_000_000_000_000))
        print("[STT][lifecycle] processRecording called (duration=\(durationMs)ms, stopping=\(isStopping))")
        stopMeteringPoll()

        // Stop recording and get the file URL
        let url = rec.url
        rec.stop()
        recorder = nil
        print("[STT][lifecycle] recorder stopped, url=\(url)")

        if !speechDetected || durationMs < minDurationMs {
            print("[STT] discarded: \(!speechDetected ? "no speech" : "too short (\(durationMs)ms)")")
            // Clean up temp file
            try? FileManager.default.removeItem(at: url)

            if isStopping {
                print("[STT][lifecycle] discarded + stopping → cleanup")
                await cleanup()
            } else {
                // Continuous mode: restart
                print("[STT][lifecycle] discarded + continuous → restarting")
                isActive = true
                isContinuousRestart = true
                await startNewRecording()
            }
            return
        }

        await setState(.processing)
        await MainActor.run { HapticService.impact(.light) }

        do {
            let data = try Data(contentsOf: url)
            let base64 = data.base64EncodedString()
            print("[STT][lifecycle] sending recording (\(durationMs)ms, \(base64.count) b64 chars)")
            await onRecordingComplete?(base64, "m4a", url)
        } catch {
            print("[STT] Failed to read recording: \(error)")
            try? FileManager.default.removeItem(at: url)
        }

        if isStopping {
            print("[STT][lifecycle] processed + stopping → cleanup")
            await cleanup()
        } else {
            // Continuous mode: restart
            print("[STT][lifecycle] processed + continuous → restarting")
            isActive = true
            isContinuousRestart = true
            await startNewRecording()
        }
    }

    private func cleanup() async {
        print("[STT][lifecycle] cleanup called")
        isActive = false
        isStopping = false
        speechDetected = false
        silenceStart = nil
        currentMeteringLevel = -160
        stopMeteringPoll()

        if let recorder {
            let url = recorder.url
            if recorder.isRecording {
                recorder.stop()
            }
            self.recorder = nil
            try? FileManager.default.removeItem(at: url)
        }

        // Switch back to playback-only in speaker mode
        if !earpieceMode {
            try? AudioSessionManager.configure(.playback)
        }

        await setState(.idle)
        print("[STT][lifecycle] cleanup done → idle")
    }

    private func startMeteringPoll() {
        stopMeteringPoll()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                await self?.handleMeteringTick()
            }
        }
    }

    private func stopMeteringPoll() {
        meteringTask?.cancel()
        meteringTask = nil
    }

    private func handleMeteringTick() async {
        guard isActive, let recorder, recorder.isRecording else {
            return
        }

        recorder.updateMeters()
        let metering = recorder.averagePower(forChannel: 0)
        currentMeteringLevel = metering
        await onMeteringUpdate?(metering)
        meteringTick += 1

        // Health-check log every ~2 seconds
        if meteringTick % 20 == 0 {
            print("[STT][health] tick=\(meteringTick) metering=\(String(format: "%.1f", metering))dB speech=\(speechDetected) active=\(isActive)")
        }

        // Dead-input detection: metering stuck below threshold
        if !speechDetected && metering <= deadInputThreshold {
            deadInputTicks += 1
            if deadInputTicks >= deadInputTickLimit {
                print("[STT][dead-input] metering stuck at \(String(format: "%.1f", metering))dB for \(deadInputTicks) ticks — full session reset")
                stopMeteringPoll()
                let deadRecorder = recorder
                self.recorder = nil

                deadRecorder.stop()
                try? FileManager.default.removeItem(at: deadRecorder.url)

                // Full deactivate/reconfigure to recover from stale hardware
                AudioSessionManager.deactivate()
                try? await Task.sleep(for: .milliseconds(100))
                do {
                    try AudioSessionManager.configure(earpieceMode ? .earpiece : .playAndRecord)
                } catch {
                    print("[STT][dead-input] Failed to reconfigure: \(error)")
                    isActive = false
                    await setState(.idle)
                    return
                }

                isActive = true
                isContinuousRestart = true  // session just configured above
                await startNewRecording()
                return
            }
        } else {
            deadInputTicks = 0
        }

        if metering > silenceThresholdDb {
            // Sound detected
            silenceStart = nil
            if !speechDetected {
                print("[STT] speech detected (metering=\(String(format: "%.1f", metering))dB)")
                speechDetected = true
                recordStart = .now
                await setState(.recording)
            }
        } else if speechDetected {
            // Silence after speech
            if silenceStart == nil {
                silenceStart = .now
            } else if let start = silenceStart {
                let elapsed = ContinuousClock.now - start
                if elapsed > .milliseconds(silenceTimeoutMs) {
                    print("[STT] silence timeout, processing recording")
                    isActive = false
                    await processRecording(recorder)
                }
            }
        }
    }

    private func setState(_ newState: State) async {
        state = newState
        await onStateChange?(newState)
    }
}
