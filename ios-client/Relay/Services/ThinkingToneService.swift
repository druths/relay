import AVFoundation

/// Plays a soft, slow-pulsing tone while the agent is thinking (status == "processing")
/// in live mode. Sounds like a single gentle ripple that repeats every ~3 seconds.
actor ThinkingToneService {
    static let shared = ThinkingToneService()

    private var player: AVAudioPlayer?
    private var pendingStart: Task<Void, Never>?

    func start() {
        guard player == nil, pendingStart == nil else { return }

        pendingStart = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let wavData = generateTone()
            do {
                let p = try AVAudioPlayer(data: wavData)
                p.numberOfLoops = -1
                p.volume = 1.0  // amplitude is baked low in the PCM data
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

    // MARK: - WAV Generation

    /// 3-second loop: a soft sine pulse at A2 (110 Hz) with a gentle perfect-fifth
    /// overtone (165 Hz) and slow FM vibrato for an organic, living quality.
    /// All frequencies chosen so the loop boundary is seamless (whole-cycle counts).
    private func generateTone() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = sampleRate * 3  // 3-second loop
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let dataSize = numSamples * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let fileSize = 44 + dataSize

        var data = Data(count: Int(fileSize))

        data.withUnsafeMutableBytes { raw in
            let ptr = raw.baseAddress!

            // RIFF header
            writeStr(ptr, 0, "RIFF")
            writeU32(ptr, 4, fileSize - 8)
            writeStr(ptr, 8, "WAVE")

            // fmt chunk
            writeStr(ptr, 12, "fmt ")
            writeU32(ptr, 16, 16)
            writeU16(ptr, 20, 1)  // PCM
            writeU16(ptr, 22, numChannels)
            writeU32(ptr, 24, sampleRate)
            writeU32(ptr, 28, sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8))
            writeU16(ptr, 32, numChannels * (bitsPerSample / 8))
            writeU16(ptr, 34, bitsPerSample)

            // data chunk
            writeStr(ptr, 36, "data")
            writeU32(ptr, 40, dataSize)

            // PCM samples
            //   Fundamental : 110 Hz (A2) — deep, warm
            //   Vibrato      : FM with β=5, rate=1/3 Hz → ±1.7 Hz deviation; completes
            //                  exactly one cycle in 3 s so the loop is phase-seamless
            //   Overtone     : 165 Hz (E3, perfect fifth) at 15% — adds warmth/organicness
            //   Envelope     : raised-cosine sin(πt), silent at both ends of the loop
            //   Amplitude    : ~20% of Int16.max so it stays a quiet background cue
            let freq    = 110.0   // Hz
            let maxAmp  = 6000.0
            let total   = Double(numSamples)
            let twoPi   = 2.0 * Double.pi
            let sr      = Double(sampleRate)

            for i in 0..<Int(numSamples) {
                let t    = Double(i) / total        // 0 → 1 (envelope position)
                let tSec = Double(i) / sr           // time in seconds

                let envelope    = sin(Double.pi * t)

                // Fundamental with gentle vibrato (FM synthesis)
                let vibrato     = 5.0 * sin(twoPi * (1.0 / 3.0) * tSec)
                let fundamental = sin(twoPi * freq * tSec + vibrato)

                // Soft perfect-fifth partial for organic warmth
                let fifth       = 0.15 * sin(twoPi * (freq * 1.5) * tSec)

                let mixed       = (fundamental + fifth) / 1.15
                var sample = Int16(maxAmp * envelope * mixed).littleEndian
                withUnsafeBytes(of: &sample) {
                    ptr.advanced(by: 44 + i * 2).copyMemory(from: $0.baseAddress!, byteCount: 2)
                }
            }
        }

        return data
    }

    private func writeStr(_ ptr: UnsafeMutableRawPointer, _ offset: Int, _ str: String) {
        for (i, byte) in str.utf8.enumerated() {
            ptr.storeBytes(of: byte, toByteOffset: offset + i, as: UInt8.self)
        }
    }

    private func writeU32(_ ptr: UnsafeMutableRawPointer, _ offset: Int, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { ptr.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: 4) }
    }

    private func writeU16(_ ptr: UnsafeMutableRawPointer, _ offset: Int, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { ptr.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: 2) }
    }
}
