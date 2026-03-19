import AVFoundation

/// Plays a soft, slow-pulsing tone while the agent is thinking (status == "processing")
/// in live mode. Sounds like a single gentle ripple that repeats every ~3 seconds.
actor ThinkingToneService {
    static let shared = ThinkingToneService()

    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }

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
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        print("[ThinkingTone] Stopped")
    }

    // MARK: - WAV Generation

    /// 3-second loop: a single soft sine pulse (330 Hz) with a raised-cosine amplitude
    /// envelope — rises from silence, peaks at 1.5s, falls back to silence.
    /// Amplitude ≈ 5% of full scale so it's a very quiet background cue.
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

            // PCM samples: one gentle sine pulse over 3 seconds
            let freq = 220.0          // Hz — low A, warm and ambient
            let maxAmp = 6553.0       // ~20% of Int16.max (32767)
            let total = Double(numSamples)
            let twoPi = 2.0 * Double.pi

            for i in 0..<Int(numSamples) {
                let t = Double(i) / total  // 0 → 1 over the full loop
                // Raised-cosine envelope: 0 at edges, 1 at centre (t=0.5)
                let envelope = sin(Double.pi * t)
                let tone = sin(twoPi * freq * Double(i) / Double(sampleRate))
                var sample = Int16(maxAmp * envelope * tone).littleEndian
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
