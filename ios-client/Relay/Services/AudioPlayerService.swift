import AVFoundation

/// Sequence-ordered MP3 chunk queue for TTS playback.
/// Ported from mobile/src/hooks/useAudioPlayer.ts.
actor AudioPlayerService {
    private var queue: [(seq: Int, data: String)] = []
    private var nextSeq: Int = 0
    private var isDraining = false
    private var isActive = false
    private(set) var isMuted = false

    // Pending stream: when a new audio_start arrives while current audio is
    // still playing, buffer incoming chunks and play after current finishes.
    private var pendingReset = false
    private var pendingQueue: [(seq: Int, data: String)] = []

    // Strong references to retain delegate during playback
    private var currentPlayer: AVAudioPlayer?
    private var currentDelegate: PlayerFinishDelegate?

    // MARK: - Public API

    func start() {
        print("[TTS] start() called (draining=\(isDraining), muted=\(isMuted))")
        if isDraining {
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

    func enqueue(data: String, sequence: Int) {
        guard !isMuted else { return }

        if pendingReset {
            print("[TTS] enqueue(seq=\(sequence)) → pending queue")
            pendingQueue.append((seq: sequence, data: data))
            pendingQueue.sort { $0.seq < $1.seq }
            return
        }

        guard isActive else { return }
        print("[TTS] enqueue(seq=\(sequence)) → active queue (\(queue.count + 1) items)")
        queue.append((seq: sequence, data: data))
        queue.sort { $0.seq < $1.seq }

        Task { await drainQueue() }
    }

    func done() {
        print("[TTS] done() called (pending=\(pendingReset))")
        if !pendingReset {
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

    /// Returns once all queued audio (including pending) has finished playing.
    /// If nothing is playing, returns immediately.
    func waitUntilFinished() async {
        while isDraining || pendingReset {
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

    private func cleanup() {
        currentPlayer?.stop()
        currentPlayer = nil
        // Resume any pending continuation so drainQueue() can exit
        currentDelegate?.cancel()
        currentDelegate = nil
    }

    private func drainQueue() async {
        guard !isDraining else { return }
        isDraining = true
        print("[TTS] drainQueue: starting (queue=\(queue.count), nextSeq=\(nextSeq))")

        do {
            while isActive && !queue.isEmpty && queue[0].seq == nextSeq {
                let item = queue.removeFirst()
                nextSeq += 1

                // Decode base64 MP3 data
                guard let audioData = Data(base64Encoded: item.data) else {
                    print("[TTS] Failed to decode base64 for seq=\(item.seq)")
                    continue
                }

                // Check muted before playing
                guard !isMuted && isActive else {
                    print("[TTS] drainQueue: muted or stopped before play — skipping")
                    isActive = false
                    queue = []
                    break
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

                print("[TTS] drainQueue: seq=\(item.seq) finished")
                currentPlayer = nil
                currentDelegate = nil
            }
        }

        isDraining = false

        // If a new stream arrived while we were playing, switch to it now
        if pendingReset {
            print("[TTS] drainQueue: pending stream swap — \(pendingQueue.count) pending chunks")
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
