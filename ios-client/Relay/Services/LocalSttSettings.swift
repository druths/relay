import Foundation

/// Per-device VAD settings for STT. These used to live in the
/// server's `platform_settings`, but each client has different mic
/// characteristics (iPhone close-field voice-processed vs. Mac
/// laptop mic vs. external USB), so one shared value is always a
/// compromise. Now stored in `UserDefaults`, local to this install.
///
/// One-time migration: new installs with no local values yet pull
/// from the server's `/v1/platform/settings` response, persist
/// locally, and never consult the server for these keys again.
/// After every client has migrated we can drop them from the GET
/// response too.
enum LocalSttSettings {
    static let defaultSilenceThresholdDb: Double = -35
    static let defaultSilenceTimeoutMs: Int = 500
    static let defaultMinDurationMs: Int = 400
    static let defaultAttackDebounceMs: Int = 300

    private static let kSilenceThresholdDb = "relay_stt_silence_threshold_db"
    private static let kSilenceTimeoutMs = "relay_stt_silence_timeout_ms"
    private static let kMinDurationMs = "relay_stt_min_duration_ms"
    private static let kAttackDebounceMs = "relay_stt_attack_debounce_ms"

    // Each getter returns `nil` when the key hasn't been written on
    // this device yet, so callers can distinguish "unset" (seed
    // from server if available) from a stored value.
    static var silenceThresholdDb: Double? {
        UserDefaults.standard.object(forKey: kSilenceThresholdDb) as? Double
    }
    static var silenceTimeoutMs: Int? {
        UserDefaults.standard.object(forKey: kSilenceTimeoutMs) as? Int
    }
    static var minDurationMs: Int? {
        UserDefaults.standard.object(forKey: kMinDurationMs) as? Int
    }
    static var attackDebounceMs: Int? {
        UserDefaults.standard.object(forKey: kAttackDebounceMs) as? Int
    }

    static func setSilenceThresholdDb(_ v: Double) {
        UserDefaults.standard.set(v, forKey: kSilenceThresholdDb)
    }
    static func setSilenceTimeoutMs(_ v: Int) {
        UserDefaults.standard.set(v, forKey: kSilenceTimeoutMs)
    }
    static func setMinDurationMs(_ v: Int) {
        UserDefaults.standard.set(v, forKey: kMinDurationMs)
    }
    static func setAttackDebounceMs(_ v: Int) {
        UserDefaults.standard.set(v, forKey: kAttackDebounceMs)
    }

    /// Resolve an effective value: use the local stored value if
    /// present, otherwise seed from a server-provided value by
    /// writing it locally and returning it. Fall through to the
    /// hard-coded default if the server didn't supply one either.
    static func resolveSilenceThresholdDb(serverFallback: Double?) -> Double {
        if let v = silenceThresholdDb { return v }
        let v = serverFallback ?? defaultSilenceThresholdDb
        setSilenceThresholdDb(v)
        return v
    }
    static func resolveSilenceTimeoutMs(serverFallback: Int?) -> Int {
        if let v = silenceTimeoutMs { return v }
        let v = serverFallback ?? defaultSilenceTimeoutMs
        setSilenceTimeoutMs(v)
        return v
    }
    static func resolveMinDurationMs(serverFallback: Int?) -> Int {
        if let v = minDurationMs { return v }
        let v = serverFallback ?? defaultMinDurationMs
        setMinDurationMs(v)
        return v
    }
    static func resolveAttackDebounceMs(serverFallback: Int?) -> Int {
        if let v = attackDebounceMs { return v }
        let v = serverFallback ?? defaultAttackDebounceMs
        setAttackDebounceMs(v)
        return v
    }
}
