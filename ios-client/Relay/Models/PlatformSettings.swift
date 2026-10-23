import Foundation

struct PlatformSettings: Codable, Equatable {
    var sttProvider: String
    var sttApiKey: String?
    var sttSilenceThresholdDb: Double
    var sttSilenceTimeoutMs: Int
    var sttMinDurationMs: Int
    var sttNoSpeechThreshold: Double
    var sttAttackDebounceMs: Int
    var voiceModeInstructions: String

    enum CodingKeys: String, CodingKey {
        case sttProvider = "stt_provider"
        case sttApiKey = "stt_api_key"
        case sttSilenceThresholdDb = "stt_silence_threshold_db"
        case sttSilenceTimeoutMs = "stt_silence_timeout_ms"
        case sttMinDurationMs = "stt_min_duration_ms"
        case sttNoSpeechThreshold = "stt_no_speech_threshold"
        case sttAttackDebounceMs = "stt_attack_debounce_ms"
        case voiceModeInstructions = "voice_mode_instructions"
    }
}
