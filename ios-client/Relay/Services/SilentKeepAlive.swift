import AVFoundation

/// Loops a silent WAV to keep the iOS audio session active during backgrounding.
/// Without this, iOS suspends the app during gaps between recorder cycles and TTS playback.
actor SilentKeepAlive {
    static let shared = SilentKeepAlive()

    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }

        do {
            let wavData = generateSilentWAV()
            let audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer.numberOfLoops = -1  // loop forever
            audioPlayer.volume = 0
            audioPlayer.play()
            player = audioPlayer
            print("[KeepAlive] Started silent audio loop")
        } catch {
            print("[KeepAlive] Failed to start: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        print("[KeepAlive] Stopped silent audio loop")
    }

    // MARK: - WAV Generation

    /// Generate 0.5s of silence: 16-bit signed PCM, mono, 8 kHz.
    private func generateSilentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 4000  // 0.5 seconds
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

            // data chunk — samples are all zeros (silence), already zeroed by Data
            writeStr(ptr, 36, "data")
            writeU32(ptr, 40, dataSize)
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
