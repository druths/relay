import AVFoundation

enum ChimeGenerator {
    private static let sampleRate: Double = 22050
    nonisolated(unsafe) private static var cachedData: Data?
    nonisolated(unsafe) private static var player: AVAudioPlayer?

    /// Play a short 280 Hz confirmation chime.
    static func play() {
        do {
            let data = cachedData ?? generateChimeWAV()
            cachedData = data

            let audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer.volume = 0.3
            audioPlayer.play()
            // Keep a strong reference until playback finishes
            player = audioPlayer
        } catch {
            print("[Chime] Failed to play: \(error)")
        }
    }

    private static func generateChimeWAV() -> Data {
        let duration: Double = 0.1
        let freq: Double = 280
        let numSamples = Int(sampleRate * duration)
        let dataSize = numSamples * 2 // 16-bit mono
        let fileSize = 44 + dataSize

        var buffer = Data(count: fileSize)

        buffer.withUnsafeMutableBytes { raw in
            let ptr = raw.baseAddress!

            // RIFF header
            writeString(ptr, offset: 0, "RIFF")
            writeUInt32(ptr, offset: 4, UInt32(fileSize - 8))
            writeString(ptr, offset: 8, "WAVE")

            // fmt chunk
            writeString(ptr, offset: 12, "fmt ")
            writeUInt32(ptr, offset: 16, 16)           // chunk size
            writeUInt16(ptr, offset: 20, 1)            // PCM
            writeUInt16(ptr, offset: 22, 1)            // mono
            writeUInt32(ptr, offset: 24, UInt32(sampleRate))
            writeUInt32(ptr, offset: 28, UInt32(sampleRate * 2)) // byte rate
            writeUInt16(ptr, offset: 32, 2)            // block align
            writeUInt16(ptr, offset: 34, 16)           // bits per sample

            // data chunk
            writeString(ptr, offset: 36, "data")
            writeUInt32(ptr, offset: 40, UInt32(dataSize))

            // Generate sine wave with fade-in/fade-out envelope
            for i in 0..<numSamples {
                let t = Double(i) / sampleRate
                let sine = sin(2.0 * .pi * freq * t)

                let envelope: Double
                if t < 0.03 {
                    envelope = t / 0.03 // fade in
                } else {
                    envelope = exp(-10 * (t - 0.03)) // exponential decay
                }

                let amplitude = 0.08
                let sample = max(-1, min(1, sine * envelope * amplitude))
                let intSample = Int16(sample * 32767)
                writeInt16(ptr, offset: 44 + i * 2, intSample)
            }
        }

        return buffer
    }

    // MARK: - WAV write helpers

    private static func writeString(_ ptr: UnsafeMutableRawPointer, offset: Int, _ str: String) {
        for (i, char) in str.utf8.enumerated() {
            ptr.storeBytes(of: char, toByteOffset: offset + i, as: UInt8.self)
        }
    }

    private static func writeUInt32(_ ptr: UnsafeMutableRawPointer, offset: Int, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            ptr.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: 4)
        }
    }

    private static func writeUInt16(_ ptr: UnsafeMutableRawPointer, offset: Int, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            ptr.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: 2)
        }
    }

    private static func writeInt16(_ ptr: UnsafeMutableRawPointer, offset: Int, _ value: Int16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            ptr.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: 2)
        }
    }
}
