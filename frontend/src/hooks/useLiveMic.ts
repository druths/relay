import { useCallback, useEffect, useRef, useState } from "react";
import { LocalSttSettings } from "../utils/localSttSettings";

/// Continuous VAD-based mic session for live mode on the web.
///
/// Design mirrors iOS's `AudioRecorderService`: open the mic once
/// when live mode starts, feed samples from an AudioWorklet into a
/// VAD state machine that detects speech segments, and fire a
/// callback with each segment's WAV bytes when the user stops
/// talking. The caller sends each segment through its normal
/// `audio_input` path; backend STT does the rest.
///
/// Why not MediaRecorder: the Opus-in-WebM path on Mac Chrome/Safari
/// intermittently returns a header-only container with zero audio
/// frames. The worklet pulls samples directly from the MediaStream
/// source, which has been reliable.
///
/// Barge-in: when speech is detected mid-TTS, `onSpeechStarted`
/// fires so the caller can send an `interrupt` to the backend and
/// stop local playback — same contract iOS uses.
///
/// VAD tuning: reads live from `LocalSttSettings`, so the four
/// per-device knobs in the settings pane (silence threshold / timeout
/// / min duration / attack debounce) take effect on the next frame
/// without restarting the session.

export interface LiveMicCallbacks {
  /** Fires once per completed speech segment with WAV bytes ready
   *  to feed `sendAudio(data, "wav")`. */
  onSegment: (data: string, format: string) => void;
  /** Fires at the moment a speech attack is confirmed — before the
   *  segment ends. Hook up to `sendInterrupt` + player stop for
   *  barge-in. */
  onSpeechStarted?: () => void;
}

export interface LiveMicHandle {
  /** True once `start()` has opened the stream + context. */
  isActive: boolean;
  /** Real-time dBFS reading from the mic. -60 silence, 0 clipping. */
  meteringLevel: number;
  /** True while the VAD state machine is actively capturing (user
   *  is talking right now). */
  speechDetected: boolean;
  /** When true, incoming frames are discarded and VAD is paused.
   *  Session stays open — easy toggle via the UI. */
  muted: boolean;
  setMuted: (muted: boolean) => void;
  start: (cb: LiveMicCallbacks) => Promise<void>;
  stop: () => void;
}

type VadState = "idle" | "attack" | "recording";

export function useLiveMic(): LiveMicHandle {
  // Session plumbing — refs survive re-renders.
  const streamRef = useRef<MediaStream | null>(null);
  const ctxRef = useRef<AudioContext | null>(null);
  const sourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const workletRef = useRef<AudioWorkletNode | null>(null);
  const workletLoadedRef = useRef(false);
  /// Monotonically-incrementing session id. Each `start()` bumps it
  /// and snapshots the new value; `stop()` also bumps it. If a
  /// `start()` awakes from an `await` and sees a mismatched id, it
  /// was superseded (React dev StrictMode double-mount or rapid
  /// user toggles) and should abort before touching nodes/context
  /// that another cycle has already torn down.
  const sessionGenRef = useRef(0);

  // VAD state.
  const vadStateRef = useRef<VadState>("idle");
  const framesRef = useRef<Float32Array[]>([]);
  const attackStartRef = useRef(0);
  const recordStartRef = useRef(0);
  const silenceStartRef = useRef<number | null>(null);
  const callbacksRef = useRef<LiveMicCallbacks | null>(null);
  const mutedRef = useRef(false);
  const frameTickRef = useRef(0);

  // React state (view-facing).
  const [isActive, setIsActive] = useState(false);
  const [meteringLevel, setMeteringLevel] = useState(-160);
  const [speechDetected, setSpeechDetected] = useState(false);
  const [muted, setMutedState] = useState(false);

  const setMuted = useCallback((v: boolean) => {
    mutedRef.current = v;
    setMutedState(v);
    if (v) {
      // Drop any in-flight capture — on unmute we start fresh.
      vadStateRef.current = "idle";
      framesRef.current = [];
      silenceStartRef.current = null;
      setSpeechDetected(false);
    }
  }, []);

  const _processFrame = useCallback((frame: Float32Array, sampleRate: number) => {
    if (mutedRef.current) return;

    // RMS → dBFS.
    let sumSq = 0;
    for (let i = 0; i < frame.length; i++) sumSq += frame[i] * frame[i];
    const rms = Math.sqrt(sumSq / frame.length);
    const db = rms > 1e-7 ? 20 * Math.log10(rms) : -160;

    // Throttle metering state updates to ~20 Hz so React doesn't
    // re-render on every 8ms worklet frame. VAD still updates every
    // frame — accurate timing matters there.
    frameTickRef.current++;
    if (frameTickRef.current % 6 === 0) setMeteringLevel(db);

    const threshold = LocalSttSettings.resolveSilenceThresholdDb(undefined);
    const attackDebounceMs = LocalSttSettings.resolveAttackDebounceMs(undefined);
    const silenceTimeoutMs = LocalSttSettings.resolveSilenceTimeoutMs(undefined);
    const minDurationMs = LocalSttSettings.resolveMinDurationMs(undefined);

    const now = performance.now();
    const state = vadStateRef.current;

    if (state === "idle") {
      if (db > threshold) {
        // Possible speech onset — enter attack. Start accumulating
        // from this frame so the eventual WAV includes the attack
        // samples (voice doesn't start clean on frame boundaries).
        vadStateRef.current = "attack";
        attackStartRef.current = now;
        framesRef.current.push(frame);
      }
    } else if (state === "attack") {
      framesRef.current.push(frame);
      if (db > threshold) {
        if (now - attackStartRef.current >= attackDebounceMs) {
          // Attack sustained long enough — confirmed speech.
          vadStateRef.current = "recording";
          recordStartRef.current = now;
          silenceStartRef.current = null;
          setSpeechDetected(true);
          callbacksRef.current?.onSpeechStarted?.();
        }
      } else {
        // False alarm (brief transient — cough, click). Drop the
        // buffered frames and reset.
        vadStateRef.current = "idle";
        framesRef.current = [];
      }
    } else {
      // Recording.
      framesRef.current.push(frame);
      if (db > threshold) {
        silenceStartRef.current = null;
      } else {
        if (silenceStartRef.current === null) {
          silenceStartRef.current = now;
        } else if (now - silenceStartRef.current >= silenceTimeoutMs) {
          // Silence has held long enough — segment is done.
          const duration = now - recordStartRef.current;
          const frames = framesRef.current;
          framesRef.current = [];
          vadStateRef.current = "idle";
          silenceStartRef.current = null;
          setSpeechDetected(false);
          if (duration >= minDurationMs) {
            // Encode + hand to caller. Fire-and-forget — we keep
            // listening regardless of whether the backend STT
            // succeeded.
            const totalSamples = frames.reduce((n, f) => n + f.length, 0);
            const merged = new Float32Array(totalSamples);
            let offset = 0;
            for (const f of frames) { merged.set(f, offset); offset += f.length; }
            const wav = _encodeWav(merged, sampleRate);
            const base64 = _base64FromBytes(wav);
            callbacksRef.current?.onSegment(base64, "wav");
          }
        }
      }
    }
  }, []);

  const start = useCallback(async (cb: LiveMicCallbacks) => {
    callbacksRef.current = cb;
    if (isActive) return;
    // Snapshot a new generation id so we can detect being
    // superseded if `stop()` runs during our awaits (common in
    // React dev StrictMode's double-mount).
    sessionGenRef.current += 1;
    const myGen = sessionGenRef.current;

    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
    if (sessionGenRef.current !== myGen) {
      // Superseded while we were waiting for the user. Release
      // the stream we just opened so the mic indicator clears.
      for (const t of stream.getTracks()) { try { t.stop(); } catch { /* ignore */ } }
      return;
    }
    streamRef.current = stream;
    const track = stream.getAudioTracks()[0];
    console.log(
      `[live-mic] track opened label=${track?.label} readyState=${track?.readyState} muted=${track?.muted}`,
    );

    const AudioCtx = window.AudioContext
      || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    const ctx = new AudioCtx({ sampleRate: 16000 });
    ctxRef.current = ctx;
    if (!workletLoadedRef.current) {
      await ctx.audioWorklet.addModule("/pcm-recorder-worklet.js");
      if (sessionGenRef.current !== myGen) {
        try { await ctx.close(); } catch { /* ignore */ }
        return;
      }
      workletLoadedRef.current = true;
    }
    if (ctx.state === "suspended") {
      await ctx.resume();
      if (sessionGenRef.current !== myGen) {
        try { await ctx.close(); } catch { /* ignore */ }
        return;
      }
    }

    const source = ctx.createMediaStreamSource(stream);
    const worklet = new AudioWorkletNode(ctx, "pcm-recorder");
    worklet.port.onmessage = (e) => {
      _processFrame(e.data as Float32Array, ctx.sampleRate);
    };
    source.connect(worklet);
    sourceRef.current = source;
    workletRef.current = worklet;

    setIsActive(true);
    console.log(`[live-mic] continuous session started sr=${ctx.sampleRate}Hz`);
  }, [isActive, _processFrame]);

  const stop = useCallback(() => {
    // Bump the session generation so any in-flight `start()`
    // awakes see they've been superseded and bail before touching
    // the context we're about to close.
    sessionGenRef.current += 1;
    try { workletRef.current?.port.postMessage("stop"); } catch { /* ignore */ }
    try { workletRef.current?.disconnect(); } catch { /* ignore */ }
    try { sourceRef.current?.disconnect(); } catch { /* ignore */ }
    workletRef.current = null;
    sourceRef.current = null;
    const s = streamRef.current;
    streamRef.current = null;
    if (s) {
      for (const t of s.getTracks()) {
        try { t.stop(); } catch { /* ignore */ }
      }
    }
    const ctx = ctxRef.current;
    ctxRef.current = null;
    if (ctx) ctx.close().catch(() => { /* ignore */ });
    workletLoadedRef.current = false;

    // Reset state so a subsequent start() begins clean.
    vadStateRef.current = "idle";
    framesRef.current = [];
    silenceStartRef.current = null;
    callbacksRef.current = null;
    frameTickRef.current = 0;
    setIsActive(false);
    setSpeechDetected(false);
    setMeteringLevel(-160);
  }, []);

  // Release on unmount so the mic indicator doesn't linger.
  const stopRef = useRef(stop);
  stopRef.current = stop;
  useEffect(() => () => stopRef.current(), []);

  return {
    isActive,
    meteringLevel,
    speechDetected,
    muted,
    setMuted,
    start,
    stop,
  };
}

// MARK: - WAV encoding helpers (unchanged from the push-to-talk
// version — same RIFF-wrapped Int16 mono format).

function _encodeWav(samples: Float32Array, sampleRate: number): Uint8Array {
  const bytesPerSample = 2;
  const numChannels = 1;
  const byteRate = sampleRate * numChannels * bytesPerSample;
  const blockAlign = numChannels * bytesPerSample;
  const dataSize = samples.length * bytesPerSample;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);
  let offset = 0;
  const writeString = (s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(offset++, s.charCodeAt(i));
  };
  const writeUint32 = (v: number) => { view.setUint32(offset, v, true); offset += 4; };
  const writeUint16 = (v: number) => { view.setUint16(offset, v, true); offset += 2; };
  writeString("RIFF");
  writeUint32(36 + dataSize);
  writeString("WAVE");
  writeString("fmt ");
  writeUint32(16);
  writeUint16(1);
  writeUint16(numChannels);
  writeUint32(sampleRate);
  writeUint32(byteRate);
  writeUint16(blockAlign);
  writeUint16(16);
  writeString("data");
  writeUint32(dataSize);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    offset += 2;
  }
  return new Uint8Array(buffer);
}

function _base64FromBytes(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
