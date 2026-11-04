import AVFoundation

/// Sequence-ordered TTS chunk queue.
/// Ported from mobile/src/hooks/useAudioPlayer.ts.
///
/// Two chunk formats:
/// - "mp3": one decodable file per chunk (per-sentence synthesis), each
///   played to completion on its own `AVAudioPlayer`.
/// - "pcm16": raw 16-bit mono samples from streaming TTS, scheduled
///   back-to-back on one `AVAudioPlayerNode` so they play gaplessly. A
///   separate engine from the recorder's, like `ThinkingToneService`.
actor AudioPlayerService {
    private struct Chunk {
        let seq: Int
        let data: String
        let format: String
        let sampleRate: Int?
    }

    private var queue: [Chunk] = []
    private var nextSeq: Int = 0
    private var isDraining = false
    private var isActive = false
    private(set) var isMuted = false

    // Pending stream: when a new audio_start arrives while current audio is
    // still playing, buffer incoming chunks and play after current finishes.
    private var pendingReset = false
    private var pendingQueue: [Chunk] = []

    // Strong references to retain delegate during playback
    private var currentPlayer: AVAudioPlayer?
    private var currentDelegate: PlayerFinishDelegate?

    // PCM streaming playback
    private var pcmEngine: AVAudioEngine?
    private var pcmNode: AVAudioPlayerNode?
    private var pcmFormat: AVAudioFormat?
    private var pcmConfigObserver: NSObjectProtocol?
    /// Buffers scheduled on the node and not yet played back.
    private var pcmOutstanding = 0
    /// Frames scheduled since the node was last idle — gates the initial
    /// `play()` until there's enough to absorb network jitter.
    private var pcmScheduledFrames: AVAudioFrameCount = 0
    /// Bumped whenever the PCM pipeline is torn down, so completion
    /// callbacks from a stopped node or dead engine are ignored.
    private var pcmGeneration = 0
    /// Audio to have queued before starting a PCM stream (same slack as web).
    private static let pcmPrebufferSeconds = 0.08

    // MARK: - Public API

    func start() {
        print("[TTS] start() called (busy=\(isBusy), muted=\(isMuted))")
        if isBusy {
            // Audio is currently playing — let it finish, then switch to new stream
            pendingReset = true
            pendingQueue = []
            return
        }
        // Nothing playing — reset immediately
        pendingReset = false
        pendingQueue = []
        cleanup()
        queue = []
        nextSeq = 0
        isDraining = false
        isActive = !isMuted
    }

    func enqueue(_ payload: AudioChunkPayload) {
        guard !isMuted else { return }
        let chunk = Chunk(seq: payload.sequence, data: payload.data, format: payload.format, sampleRate: payload.sampleRate)

        if pendingReset {
            pendingQueue.append(chunk)
            pendingQueue.sort { $0.seq < $1.seq }
            return
        }

        guard isActive else { return }
        queue.append(chunk)
        queue.sort { $0.seq < $1.seq }

        Task { await drainQueue() }
    }

    func done() {
        print("[TTS] done() called (pending=\(pendingReset))")
        if !pendingReset {
            // The reply's audio is complete: start a short PCM stream that
            // never reached the prebuffer threshold.
            startPCMIfReady(force: true)
            Task { await drainQueue() }
        }
    }

    func stop() {
        print("[TTS] stop() — clearing \(queue.count) queued")
        isActive = false
        pendingReset = false
        pendingQueue = []
        cleanup()
        queue = []
        nextSeq = 0
    }

    /// True if TTS audio is currently being played — i.e., the user would
    /// hear it. Used by the thinking-tone gating so we don't play the tone
    /// over agent speech.
    func isPlaying() -> Bool {
        isBusy
    }

    /// Returns once all queued audio (including pending) has finished playing.
    /// If nothing is playing, returns immediately.
    func waitUntilFinished() async {
        while isBusy || pendingReset {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            isActive = false
            pendingReset = false
            pendingQueue = []
            cleanup()
            queue = []
        }
    }

    // MARK: - Private

    private var isBusy: Bool { isDraining || pcmBusy }

    /// Scheduled PCM still to be heard. A stopped engine (route change,
    /// interruption) can drop buffers without calling back, so it never
    /// counts as busy — otherwise `waitUntilFinished` would hang a session
    /// handoff.
    private var pcmBusy: Bool {
        pcmOutstanding > 0 && (pcmEngine?.isRunning ?? false)
    }

    private func cleanup() {
        currentPlayer?.stop()
        currentPlayer = nil
        // Resume any pending continuation so drainQueue() can exit
        currentDelegate?.cancel()
        currentDelegate = nil
        teardownPCM()
    }

    private func drainQueue() async {
        guard !isDraining else { return }
        isDraining = true

        do {
            while isActive && !queue.isEmpty && queue[0].seq == nextSeq {
                let item = queue.removeFirst()
                nextSeq += 1

                // Decode base64 audio data (empty = failed synthesis upstream)
                guard let audioData = Data(base64Encoded: item.data), !audioData.isEmpty else {
                    continue
                }

                // Check muted before playing
                guard !isMuted && isActive else {
                    print("[TTS] drainQueue: muted or stopped before play — skipping")
                    isActive = false
                    queue = []
                    break
                }

                if item.format == "pcm16" {
                    schedulePCM(audioData, sampleRate: Double(item.sampleRate ?? 24000))
                    continue
                }

                // MP3 after streamed PCM: let the stream finish first.
                while pcmBusy {
                    try? await Task.sleep(for: .milliseconds(20))
                }

                let player: AVAudioPlayer
                do {
                    player = try AVAudioPlayer(data: audioData)
                } catch {
                    print("[TTS] Failed to create player for seq=\(item.seq): \(error)")
                    continue
                }

                player.prepareToPlay()
                self.currentPlayer = player

                // Play and wait for finish with timeout
                print("[TTS] drainQueue: playing seq=\(item.seq)")
                do {
                    try await withTimeout(seconds: 30, label: "playChunk(seq=\(item.seq))") {
                        await self.playCurrentAndWait()
                    }
                } catch {
                    print("[TTS] Playback timeout/error for seq=\(item.seq): \(error)")
                    currentPlayer?.stop()
                }

                currentPlayer = nil
                currentDelegate = nil
            }
        }

        isDraining = false
        await swapToPendingStreamIfIdle()
    }

    /// If a new stream arrived while we were playing, switch to it once
    /// the current one has been fully heard. Called when the MP3 drain
    /// loop exits and when the last scheduled PCM buffer plays out.
    private func swapToPendingStreamIfIdle() async {
        guard pendingReset, !isBusy else { return }
        print("[TTS] pending stream swap — \(pendingQueue.count) pending chunks")
        pendingReset = false
        cleanup()
        queue = pendingQueue
        pendingQueue = []
        nextSeq = 0
        isActive = !isMuted

        if !queue.isEmpty && isActive {
            await drainQueue()
        }
    }

    private func playCurrentAndWait() async {
        guard let player = currentPlayer else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = PlayerFinishDelegate(continuation: continuation)
            self.currentDelegate = delegate
            player.delegate = delegate
            player.play()
        }
    }

    // MARK: - PCM streaming

    private func schedulePCM(_ data: Data, sampleRate: Double) {
        guard let node = ensurePCMEngine(sampleRate: sampleRate), let format = pcmFormat else { return }
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                channel[i] = Float(sample) / 32768
            }
        }

        let generation = pcmGeneration
        pcmOutstanding += 1
        pcmScheduledFrames += buffer.frameLength
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { await self.pcmBufferPlayed(generation: generation) }
        }
        startPCMIfReady(force: false)
    }

    /// Start (or resume, after an underrun) the node once enough audio is
    /// queued to ride out jitter — or immediately when `force`d at the end
    /// of a reply.
    private func startPCMIfReady(force: Bool) {
        guard let node = pcmNode, let format = pcmFormat, !node.isPlaying, pcmOutstanding > 0 else { return }
        let threshold = AVAudioFrameCount(format.sampleRate * Self.pcmPrebufferSeconds)
        if force || pcmScheduledFrames >= threshold {
            node.play()
        }
    }

    private func pcmBufferPlayed(generation: Int) async {
        guard generation == pcmGeneration else { return }
        pcmOutstanding = max(0, pcmOutstanding - 1)
        if pcmOutstanding == 0 {
            // Ran dry: pause so the next chunk prebuffers again instead of
            // clicking in the instant it lands.
            pcmNode?.pause()
            pcmScheduledFrames = 0
            await swapToPendingStreamIfIdle()
        }
    }

    private func ensurePCMEngine(sampleRate: Double) -> AVAudioPlayerNode? {
        if let engine = pcmEngine, let node = pcmNode, engine.isRunning, pcmFormat?.sampleRate == sampleRate {
            return node
        }
        // No engine yet, a different rate, or the engine was stopped (route
        // change, interruption): start over. Buffers it held are gone.
        teardownPCM()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            return nil
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            print("[TTS] PCM engine start failed: \(error)")
            return nil
        }
        let generation = pcmGeneration
        pcmConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
        ) { _ in
            Task { await self.pcmEngineConfigurationChanged(generation: generation) }
        }
        pcmEngine = engine
        pcmNode = node
        pcmFormat = format
        print("[TTS] PCM engine started at \(Int(sampleRate)) Hz")
        return node
    }

    /// The output route changed (e.g. Bluetooth switching profile when the
    /// recorder starts) and the engine stopped. Drop it; the next chunk
    /// rebuilds one on the new route.
    private func pcmEngineConfigurationChanged(generation: Int) async {
        guard generation == pcmGeneration else { return }
        print("[TTS] PCM engine configuration changed — rebuilding on next chunk")
        teardownPCM()
        await swapToPendingStreamIfIdle()
    }

    private func teardownPCM() {
        pcmGeneration += 1
        if let observer = pcmConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            pcmConfigObserver = nil
        }
        pcmNode?.stop()
        pcmEngine?.stop()
        pcmNode = nil
        pcmEngine = nil
        pcmFormat = nil
        pcmOutstanding = 0
        pcmScheduledFrames = 0
    }

    private func withTimeout<T: Sendable>(seconds: Double, label: String, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError(label: label, seconds: seconds)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    struct TimeoutError: Error, CustomStringConvertible {
        let label: String
        let seconds: Double
        var description: String { "\(label): timed out after \(seconds)s" }
    }
}

// MARK: - AVAudioPlayerDelegate bridge

private final class PlayerFinishDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func cancel() {
        continuation?.resume()
        continuation = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        continuation?.resume()
        continuation = nil
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        continuation?.resume()
        continuation = nil
    }
}
