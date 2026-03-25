import AVFoundation

/// Plays a looping tone while the agent is thinking (status == "processing") in live mode.
/// Starts with a 1-second delay so short responses don't trigger it.
actor ThinkingToneService {
    static let shared = ThinkingToneService()

    private var player: AVAudioPlayer?
    private var pendingStart: Task<Void, Never>?

    func start() {
        guard player == nil, pendingStart == nil else { return }

        pendingStart = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let url = Bundle.main.url(forResource: "thinking_1", withExtension: "wav") else {
                print("[ThinkingTone] Missing bundle resource: thinking_1.wav")
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.play()
                player = p
                print("[ThinkingTone] Started")
            } catch {
                print("[ThinkingTone] Failed to start: \(error)")
            }
            pendingStart = nil
        }
    }

    func stop() {
        pendingStart?.cancel()
        pendingStart = nil
        guard player != nil else { return }
        player?.stop()
        player = nil
        print("[ThinkingTone] Stopped")
    }
}
