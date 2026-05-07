import AVFoundation

/// VAD-based audio recorder with silence detection, dead-input recovery, and continuous mode.
/// Uses AVAudioEngine + isVoiceProcessingEnabled for hardware noise suppression and AEC.
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
    var attackDebounceMs: Int = 300
    var earpieceMode: Bool = false

    // MARK: - Callbacks

    var onRecordingComplete: (@Sendable (String, String, URL) async -> Void)?
    var onStateChange: (@Sendable (State) async -> Void)?
    var onMeteringUpdate: (@Sendable (Float) async -> Void)?

    // MARK: - Metering

    private(set) var currentMeteringLevel: Float = -160

    // MARK: - Internal state

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private var tapFormat: AVAudioFormat?
    private var meteringTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var isActive = false
    private var isStopping = false
    private var speechDetected = false
    private var silenceStart: ContinuousClock.Instant?
    private var recordStart: ContinuousClock.Instant?
    private var attackStart: ContinuousClock.Instant?
    private var preferredInput: AVAudioSessionPortDescription?
    private var meteringTick = 0
    private var deadInputTicks = 0
    private var engineStoppedTicks = 0
    private var isContinuousRestart = false

    private let deadInputThreshold: Float = -100
    private let deadInputTickLimit = 5
    private let engineStoppedTickLimit = 3

    // MARK: - Public API

    func startListening() async {
        print("[STT][lifecycle] startListening called (stopping=\(isStopping), active=\(isActive), state=\(state))")
        let priorState = state
        let priorActive = isActive
        Task { @MainActor in
            ActivityLog.shared.add("recording_start_requested", context: [
                "prior_state": String(describing: priorState),
                "prior_active": priorActive,
            ])
        }
        await cleanup()

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
        isContinuousRestart = true

        registerInterruptionObserver()
        print("[STT][lifecycle] startListening → startEngine")
        await startEngine()
    }

    func stopListening() async {
        print("[STT][lifecycle] stopListening called (speech=\(speechDetected), active=\(isActive), stopping=\(isStopping))")
        let hadSpeech = speechDetected
        let priorState = state
        Task { @MainActor in
            ActivityLog.shared.add("recording_stop_requested", context: [
                "had_speech": hadSpeech,
                "prior_state": String(describing: priorState),
            ])
        }
        isStopping = true
        isActive = false
        stopMeteringPoll()

        if speechDetected {
            print("[STT][lifecycle] stopListening: has speech → processRecording")
            await processRecording()
        } else {
            print("[STT][lifecycle] stopListening: no speech → cleanup")
            await cleanup()
        }
    }

    /// No-op: AVAudioEngine + isVoiceProcessingEnabled handles AEC at the OS level.
    func discardAndRestartRecording() async {
        print("[STT][echo-flush] discardAndRestartRecording — no-op (AEC active)")
    }

    func setPreferredInput(_ port: AVAudioSessionPortDescription) {
        preferredInput = port
        try? AVAudioSession.sharedInstance().setPreferredInput(port)
    }

    func setMuted(_ muted: Bool) {
        if muted {
            stopMeteringPoll()
            engine?.inputNode.removeTap(onBus: 0)
            currentMeteringLevel = -160
            Task { await onMeteringUpdate?(-160) }
            print("[STT] mic muted")
        } else {
            if let engine, let tapFormat {
                installTap(on: engine, format: tapFormat)
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

    private func startEngine() async {
        print("[STT][lifecycle] startEngine (active=\(isActive), continuous=\(isContinuousRestart), stopping=\(isStopping))")
        guard isActive else {
            print("[STT][lifecycle] startEngine: bailing — not active")
            return
        }

        speechDetected = false
        silenceStart = nil
        attackStart = nil
        meteringTick = 0
        deadInputTicks = 0
        engineStoppedTicks = 0
        currentMeteringLevel = -160
        await setState(.listening)

        do {
            if !isContinuousRestart {
                try AudioSessionManager.configure(earpieceMode ? .earpiece : .playAndRecord)
            }
            isContinuousRestart = false

            if let preferred = preferredInput {
                try? AVAudioSession.sharedInstance().setPreferredInput(preferred)
            }

            let newEngine = AVAudioEngine()

            // Enable voice processing (NS + AEC) — must be called before prepare()
            try? newEngine.inputNode.setVoiceProcessingEnabled(true)

            newEngine.prepare()
            try newEngine.start()
            engine = newEngine

            // Request mono Float32 tap at the hardware sample rate
            let nativeSampleRate = newEngine.inputNode.outputFormat(forBus: 0).sampleRate
            guard let monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: nativeSampleRate, channels: 1
            ) else { throw NSError(domain: "AudioRecorder", code: -1, userInfo: nil) }
            tapFormat = monoFormat

            // Prepare WAV output file (Int16 PCM, mono)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay_recording_\(UUID().uuidString).wav")
            let wavSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: nativeSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            // commonFormat: .pcmFormatFloat32 — write(from:) accepts Float32 buffers,
            // AVAudioFile converts to Int16 PCM on disk automatically.
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: wavSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            audioFileURL = url

            installTap(on: newEngine, format: monoFormat)
            print("[STT][lifecycle] engine started, tap installed (sr=\(nativeSampleRate)Hz mono)")

            await SilentKeepAlive.shared.start()
            startMeteringPoll()
        } catch {
            print("[STT] Failed to start engine: \(error)")
            await cleanup()
        }
    }

    private func installTap(on engine: AVAudioEngine, format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy samples synchronously before crossing the concurrency boundary.
            // [Float] is Sendable; AVAudioPCMBuffer is not.
            let frameCount = Int(buffer.frameLength)
            var samples = [Float](repeating: 0, count: frameCount)
            if let src = buffer.floatChannelData?[0], frameCount > 0 {
                memcpy(&samples, src, frameCount * MemoryLayout<Float>.size)
            }
            Task { await self.handleTapData(samples: samples) }
        }
    }

    private func handleTapData(samples: [Float]) async {
        guard isActive else { return }

        // Reconstruct buffer from copied samples and write to file
        if let file = audioFile,
           let format = tapFormat,
           let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples.count)) {
            writeBuffer.frameLength = UInt32(samples.count)
            if let dst = writeBuffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        dst.assign(from: base, count: samples.count)
                    }
                }
            }
            try? file.write(from: writeBuffer)
        }

        // Compute RMS → dB
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = samples.isEmpty ? 0 : sqrt(sumSquares / Float(samples.count))
        let db: Float = rms > 1e-9 ? 20 * log10(rms) : -160

        currentMeteringLevel = db
        await onMeteringUpdate?(db)

        // VAD state machine
        if db > silenceThresholdDb {
            silenceStart = nil
            if !speechDetected {
                let now = ContinuousClock.now
                if attackStart == nil { attackStart = now }
                if now - attackStart! >= .milliseconds(attackDebounceMs) {
                    print("[STT] speech detected (db=\(String(format: "%.1f", db)), sustained \(attackDebounceMs)ms)")
                    speechDetected = true
                    attackStart = nil
                    recordStart = .now
                    await setState(.recording)
                }
            }
        } else {
            attackStart = nil
            if speechDetected {
                if silenceStart == nil {
                    silenceStart = .now
                } else if ContinuousClock.now - silenceStart! >= .milliseconds(silenceTimeoutMs) {
                    print("[STT] silence timeout, processing recording")
                    await processRecording()
                }
            }
        }
    }

    private func processRecording() async {
        let durationMs: Int
        if let start = recordStart {
            let d = ContinuousClock.now - start
            durationMs = Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
        } else {
            durationMs = 0
        }
        let hadSpeech = speechDetected
        print("[STT][lifecycle] processRecording (duration=\(durationMs)ms, stopping=\(isStopping), hadSpeech=\(hadSpeech))")

        if isStopping {
            // Full teardown — engine stops here
            stopMeteringPoll()
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            audioFile = nil
            let url = audioFileURL
            audioFileURL = nil

            if hadSpeech && durationMs >= minDurationMs, let url {
                await setState(.processing)
                await MainActor.run { HapticService.impact(.light) }
                do {
                    let data = try Data(contentsOf: url)
                    let base64 = data.base64EncodedString()
                    print("[STT][lifecycle] sending recording (\(durationMs)ms, \(base64.count) b64 chars)")
                    await onRecordingComplete?(base64, "wav", url)
                } catch {
                    print("[STT] Failed to read recording: \(error)")
                    try? FileManager.default.removeItem(at: url)
                }
            } else if let url {
                print("[STT] discarded: \(!hadSpeech ? "no speech" : "too short (\(durationMs)ms)")")
                try? FileManager.default.removeItem(at: url)
            }
            await cleanup()
            return
        }

        // Continuous mode: rotate the audio file, keep engine and tap running.
        // All file operations are synchronous (no await) so the tap sees a valid
        // audioFile the next time handleTapData runs on the actor.
        let oldURL = audioFileURL
        audioFile = nil        // flushes and closes the AVAudioFile on disk
        audioFileURL = nil
        openNewAudioFile()     // new file ready before any queued tap tasks run

        // Reset VAD state for the next utterance
        speechDetected = false
        silenceStart = nil
        attackStart = nil
        recordStart = nil
        await setState(.listening)

        guard let url = oldURL else { return }

        if !hadSpeech || durationMs < minDurationMs {
            print("[STT] discarded: \(!hadSpeech ? "no speech" : "too short (\(durationMs)ms)")")
            try? FileManager.default.removeItem(at: url)
            return
        }

        await setState(.processing)
        await MainActor.run { HapticService.impact(.light) }

        do {
            let data = try Data(contentsOf: url)
            let base64 = data.base64EncodedString()
            print("[STT][lifecycle] sending recording (\(durationMs)ms, \(base64.count) b64 chars)")
            await onRecordingComplete?(base64, "wav", url)
        } catch {
            print("[STT] Failed to read recording: \(error)")
            try? FileManager.default.removeItem(at: url)
        }

        await setState(.listening)
    }

    private func openNewAudioFile() {
        guard let tapFormat else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay_recording_\(UUID().uuidString).wav")
        let wavSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: tapFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: wavSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            audioFileURL = url
        } catch {
            print("[STT] Failed to open new audio file: \(error)")
        }
    }

    private func cleanup() async {
        print("[STT][lifecycle] cleanup (stopping=\(isStopping), active=\(isActive), state=\(state))")
        removeInterruptionObserver()
        isActive = false
        isStopping = false
        speechDetected = false
        silenceStart = nil
        attackStart = nil
        currentMeteringLevel = -160
        stopMeteringPoll()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil

        if let url = audioFileURL {
            try? FileManager.default.removeItem(at: url)
            audioFileURL = nil
        }

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
                await self?.handleHealthTick()
            }
        }
    }

    private func stopMeteringPoll() {
        meteringTask?.cancel()
        meteringTask = nil
    }

    // MARK: - Health check

    private func handleHealthTick() async {
        guard isActive else { return }
        meteringTick += 1

        guard let engine else {
            print("[STT][health] isActive=true but engine=nil")
            return
        }

        guard engine.isRunning else {
            engineStoppedTicks += 1
            if engineStoppedTicks >= engineStoppedTickLimit {
                print("[STT][recovery] engine stopped for \(engineStoppedTicks) ticks — recovering")
                engineStoppedTicks = 0
                stopMeteringPoll()
                self.engine?.inputNode.removeTap(onBus: 0)
                self.engine = nil
                audioFile = nil
                if let url = audioFileURL {
                    try? FileManager.default.removeItem(at: url)
                    audioFileURL = nil
                }
                do {
                    try AudioSessionManager.configure(earpieceMode ? .earpiece : .playAndRecord)
                } catch {
                    print("[STT][recovery] configure failed: \(error)")
                    return
                }
                isActive = true
                isContinuousRestart = true
                await startEngine()
            }
            return
        }
        engineStoppedTicks = 0

        if meteringTick % 20 == 0 {
            print("[STT][health] tick=\(meteringTick) db=\(String(format: "%.1f", currentMeteringLevel))dB speech=\(speechDetected)")
        }

        // Dead-input detection: currentMeteringLevel stuck far below threshold
        if !speechDetected && currentMeteringLevel <= deadInputThreshold {
            deadInputTicks += 1
            if deadInputTicks >= deadInputTickLimit {
                print("[STT][dead-input] stuck at \(String(format: "%.1f", currentMeteringLevel))dB — full reset")
                stopMeteringPoll()
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                self.engine = nil
                audioFile = nil
                if let url = audioFileURL {
                    try? FileManager.default.removeItem(at: url)
                    audioFileURL = nil
                }
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
                isContinuousRestart = true
                await startEngine()
            }
        } else {
            deadInputTicks = 0
        }
    }

    // MARK: - Audio Session Interruption

    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { await self.handleAudioInterruption(typeValue: typeValue, optionsValue: optionsValue) }
        }
    }

    private func removeInterruptionObserver() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
    }

    private func handleAudioInterruption(typeValue: UInt?, optionsValue: UInt) async {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("[STT][interruption] Audio session interrupted")
            stopMeteringPoll()
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            audioFile = nil
            if let url = audioFileURL {
                try? FileManager.default.removeItem(at: url)
                audioFileURL = nil
            }
            // Leave isActive=true so .ended handler restarts

        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            print("[STT][interruption] Interruption ended (shouldResume=\(shouldResume), isActive=\(isActive))")
            guard isActive else { return }

            AudioSessionManager.deactivate()
            try? await Task.sleep(for: .milliseconds(200))
            do {
                try AudioSessionManager.configure(earpieceMode ? .earpiece : .playAndRecord)
            } catch {
                print("[STT][interruption] Failed to reconfigure: \(error)")
                isActive = false
                await setState(.idle)
                return
            }
            isContinuousRestart = true
            await startEngine()

        @unknown default:
            break
        }
    }

    private func setState(_ newState: State) async {
        state = newState
        await onStateChange?(newState)
    }
}
