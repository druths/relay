import AVFoundation

enum ChimeGenerator {
    // Keep strong references until playback finishes
    nonisolated(unsafe) private static var responsePlayer: AVAudioPlayer?
    nonisolated(unsafe) private static var liveStartPlayer: AVAudioPlayer?
    nonisolated(unsafe) private static var sessionLeaveEngine: AVAudioEngine?

    /// Plays when the user's response has been received and is being processed.
    static func play() {
        playSound("response_received_1", playerRef: &responsePlayer)
    }

    static func playLiveStart() {
        playSound("live_start_1", playerRef: &liveStartPlayer)
    }

    /// Synthesised descending two-note tone for leaving a session in live mode.
    /// E5 → A4, ~350 ms total, with a soft fade to avoid clicks.
    static func playSessionLeave() {
        let sampleRate = 44100.0
        let duration = 0.35
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        let totalFrames = Int(frameCount)
        let halfFrames = totalFrames / 2
        guard let channel = buffer.floatChannelData?[0] else { return }

        for i in 0..<halfFrames {
            let t = Double(i) / sampleRate
            let progress = Double(i) / Double(halfFrames)
            let envelope = sin(.pi * progress) * 0.25  // soft attack/decay
            channel[i] = Float(sin(2.0 * .pi * 659.25 * t) * envelope)
        }
        for i in halfFrames..<totalFrames {
            let local = i - halfFrames
            let t = Double(local) / sampleRate
            let progress = Double(local) / Double(totalFrames - halfFrames)
            let envelope = sin(.pi * progress) * 0.25
            channel[i] = Float(sin(2.0 * .pi * 440.0 * t) * envelope)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                Task { @MainActor in
                    engine.stop()
                    if sessionLeaveEngine === engine { sessionLeaveEngine = nil }
                }
            }
            player.play()
            sessionLeaveEngine = engine
        } catch {
            print("[Sound] Failed to play session-leave tone: \(error)")
        }
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
