/**
 * Per-device VAD settings for STT. These used to live in the server's
 * `platform_settings`, but each client has different mic
 * characteristics (laptop built-in vs USB headset vs iPhone
 * close-field), so one shared value is always a compromise. Now
 * stored in `localStorage`, local to this browser profile.
 *
 * One-time migration: new installs with no local value yet pull from
 * the server's `/v1/platform/settings` response, persist locally, and
 * never consult the server for these keys again. After every client
 * has migrated we can drop them from the GET response too.
 */

export const DEFAULT_SILENCE_THRESHOLD_DB = -35;
export const DEFAULT_SILENCE_TIMEOUT_MS = 500;
export const DEFAULT_MIN_DURATION_MS = 400;
export const DEFAULT_ATTACK_DEBOUNCE_MS = 300;

const KEYS = {
  silenceThresholdDb: "relay_stt_silence_threshold_db",
  silenceTimeoutMs: "relay_stt_silence_timeout_ms",
  minDurationMs: "relay_stt_min_duration_ms",
  attackDebounceMs: "relay_stt_attack_debounce_ms",
} as const;

function _readNumber(key: string): number | null {
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return null;
    const n = Number(raw);
    return Number.isFinite(n) ? n : null;
  } catch {
    return null;
  }
}

function _writeNumber(key: string, value: number) {
  try {
    localStorage.setItem(key, String(value));
  } catch {
    /* private window / quota — fall through */
  }
}

export const LocalSttSettings = {
  getSilenceThresholdDb: (): number | null => _readNumber(KEYS.silenceThresholdDb),
  getSilenceTimeoutMs: (): number | null => _readNumber(KEYS.silenceTimeoutMs),
  getMinDurationMs: (): number | null => _readNumber(KEYS.minDurationMs),
  getAttackDebounceMs: (): number | null => _readNumber(KEYS.attackDebounceMs),

  setSilenceThresholdDb: (v: number) => _writeNumber(KEYS.silenceThresholdDb, v),
  setSilenceTimeoutMs: (v: number) => _writeNumber(KEYS.silenceTimeoutMs, v),
  setMinDurationMs: (v: number) => _writeNumber(KEYS.minDurationMs, v),
  setAttackDebounceMs: (v: number) => _writeNumber(KEYS.attackDebounceMs, v),

  /** Resolve an effective value: use the local stored value if
   *  present, otherwise seed from a server-provided value by writing
   *  it locally and returning it. Falls back to the hard-coded
   *  default if the server didn't supply one either. */
  resolveSilenceThresholdDb(serverFallback: number | undefined): number {
    const existing = _readNumber(KEYS.silenceThresholdDb);
    if (existing !== null) return existing;
    const v = serverFallback ?? DEFAULT_SILENCE_THRESHOLD_DB;
    _writeNumber(KEYS.silenceThresholdDb, v);
    return v;
  },
  resolveSilenceTimeoutMs(serverFallback: number | undefined): number {
    const existing = _readNumber(KEYS.silenceTimeoutMs);
    if (existing !== null) return existing;
    const v = serverFallback ?? DEFAULT_SILENCE_TIMEOUT_MS;
    _writeNumber(KEYS.silenceTimeoutMs, v);
    return v;
  },
  resolveMinDurationMs(serverFallback: number | undefined): number {
    const existing = _readNumber(KEYS.minDurationMs);
    if (existing !== null) return existing;
    const v = serverFallback ?? DEFAULT_MIN_DURATION_MS;
    _writeNumber(KEYS.minDurationMs, v);
    return v;
  },
  resolveAttackDebounceMs(serverFallback: number | undefined): number {
    const existing = _readNumber(KEYS.attackDebounceMs);
    if (existing !== null) return existing;
    const v = serverFallback ?? DEFAULT_ATTACK_DEBOUNCE_MS;
    _writeNumber(KEYS.attackDebounceMs, v);
    return v;
  },
};
