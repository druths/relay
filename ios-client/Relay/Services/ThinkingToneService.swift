import AVFoundation

/// Plays a soft heartbeat ("lub-dub") tone while the agent is thinking
/// (status == "processing") in live mode. Synthesised on the fly so we don't
/// ship a bundled WAV.
///
/// Pattern (one cycle ≈ 1.5 s, looped):
///   • Tone A at full amplitude (the "lub")
///   • 300 ms silence
///   • Tone A again at reduced amplitude (the quieter "dub")
///   • Long silence before the next heartbeat
///
/// Each tone has a sine-shaped attack/decay envelope and a soft amplitude
/// so it doesn't crowd the agent's voice (the RelayViewModel still gates
/// the tone so it never overlaps TTS playback).
///
/// A 1-second arming delay before playback ensures short responses don't
/// trigger any audible tone.
actor ThinkingToneService {
    static let shared = ThinkingToneService()

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var pendingStart: Task<Void, Never>?

    // ── Pattern parameters ──
    private let sampleRate: Double = 44_100
    private let toneA: Double = 196.00      // G3
    private let lubDuration: Double = 0.18  // the first beat (full)
    private let dubDuration: Double = 0.20  // the second beat (quieter, slightly longer for "thud")
    private let beatGapDuration: Double = 0.30   // pause between lub and dub
    private let restDuration: Double = 0.80      // pause between heartbeats
    private let lubAmplitude: Float = 0.14
    private let dubAmplitude: Float = 0.07

    func start() {
        guard engine == nil, pendingStart == nil else { return }
        pendingStart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.actuallyStart()
        }
    }

    func stop() {
        pendingStart?.cancel()
        pendingStart = nil
        guard let p = playerNode, let e = engine else { return }
        p.stop()
        e.stop()
        playerNode = nil
        engine = nil
        print("[ThinkingTone] Stopped")
    }

    // MARK: - Private

    private func actuallyStart() {
        pendingStart = nil
        guard let buffer = buildLoopBuffer() else {
            print("[ThinkingTone] Failed to build buffer")
            return
        }
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: buffer.format)
        do {
            try e.start()
        } catch {
            print("[ThinkingTone] Engine start failed: \(error)")
            return
        }
        p.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        p.play()
        engine = e
        playerNode = p
        print("[ThinkingTone] Started")
    }

    /// One full heartbeat cycle: lub, 300ms gap, quieter dub, long rest.
    /// Looped by the player node via `.loops`.
    private func buildLoopBuffer() -> AVAudioPCMBuffer? {
        let cycleDuration = lubDuration + beatGapDuration + dubDuration + restDuration
        let frameCount = AVAudioFrameCount(sampleRate * cycleDuration)
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount

        guard let channel = buffer.floatChannelData?[0] else { return nil }

        let lubFrames = Int(sampleRate * lubDuration)
        let dubFrames = Int(sampleRate * dubDuration)
        let beatGapFrames = Int(sampleRate * beatGapDuration)

        var cursor = 0
        writeTone(into: channel, start: cursor, frames: lubFrames, frequency: toneA, amplitude: lubAmplitude)
        cursor += lubFrames
        zero(into: channel, start: cursor, frames: beatGapFrames)
        cursor += beatGapFrames
        writeTone(into: channel, start: cursor, frames: dubFrames, frequency: toneA, amplitude: dubAmplitude)
        cursor += dubFrames
        // Trailing rest fills the remainder of the buffer.
        let remaining = Int(frameCount) - cursor
        if remaining > 0 {
            zero(into: channel, start: cursor, frames: remaining)
        }
        return buffer
    }

    private func writeTone(
        into channel: UnsafeMutablePointer<Float>,
        start: Int, frames: Int, frequency: Double, amplitude: Float,
    ) {
        let omega = 2.0 * .pi * frequency
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let progress = Double(i) / Double(frames)
            // Half-sine envelope: smooth attack + decay, peaks in the middle.
            let env = sin(.pi * progress)
            channel[start + i] = Float(sin(omega * t) * env) * amplitude
        }
    }

    private func zero(into channel: UnsafeMutablePointer<Float>, start: Int, frames: Int) {
        for i in 0..<frames { channel[start + i] = 0 }
    }
}
