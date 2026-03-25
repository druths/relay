import AVFoundation

enum ChimeGenerator {
    // Keep strong references until playback finishes
    nonisolated(unsafe) private static var responsePlayer: AVAudioPlayer?
    nonisolated(unsafe) private static var liveStartPlayer: AVAudioPlayer?
    nonisolated(unsafe) private static var liveEndPlayer: AVAudioPlayer?

    /// Plays when the user's response has been received and is being processed.
    static func play() {
        playSound("response_received_1", playerRef: &responsePlayer)
    }

    static func playLiveStart() {
        playSound("live_start_1", playerRef: &liveStartPlayer)
    }

    static func playLiveEnd() {
        playSound("live_end_1", playerRef: &liveEndPlayer)
    }

    private static func playSound(_ name: String, playerRef: inout AVAudioPlayer?) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            print("[Sound] Missing bundle resource: \(name).wav")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            playerRef = p
        } catch {
            print("[Sound] Failed to play \(name): \(error)")
        }
    }
}
