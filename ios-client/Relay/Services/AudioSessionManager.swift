import AVFoundation

enum AudioSessionMode: Sendable {
    /// Playback only — TTS output through speaker. No recording.
    case playback
    /// Recording + playback — mic enabled, audio through speaker.
    case playAndRecord
    /// Earpiece mode — mic enabled, audio through earpiece.
    case earpiece
}

enum AudioSessionManager {
    static func configure(_ mode: AudioSessionMode) throws {
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .playback:
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            print("[AudioSession] Configured: playback")

        case .playAndRecord:
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
            print("[AudioSession] Configured: playAndRecord (speaker)")

        case .earpiece:
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth]
            )
            try session.overrideOutputAudioPort(.none)
            try session.setActive(true)
            print("[AudioSession] Configured: playAndRecord (earpiece)")
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[AudioSession] Deactivated")
    }
}
