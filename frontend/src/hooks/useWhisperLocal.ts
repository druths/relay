import { useCallback, useEffect, useRef, useState } from "react";
import { pipeline, type AutomaticSpeechRecognitionPipeline } from "@huggingface/transformers";

/// On-device STT via `onnx-community/whisper-large-v3-turbo`,
/// int8-quantized, running through transformers.js on WebGPU.
///
/// Why turbo-int8: it's the sweet spot — ~400 MB download, 1 GB
/// RAM, ~95% of `large-v3` accuracy, and runs faster than realtime
/// on M-series + WebGPU. Vanilla `large-v3` doubles both without a
/// meaningful quality improvement for our segmented live-mode use.
///
/// Requires WebGPU. On browsers without it (older Safari / most
/// Firefox) the hook surfaces an error and the caller falls back
/// to a cloud STT provider.
///
/// Model files are kept in the browser's Cache API by transformers.js,
/// so only the first load hits the network. The loaded pipeline is a
/// page-wide singleton: live-mode controls mount and unmount with every
/// mic toggle, and a per-mount pipeline meant re-initialising the model
/// on the GPU (and leaking the previous one) each time.
export interface WhisperLocalHandle {
  /** True once the pipeline is loaded and ready to transcribe. */
  isReady: boolean;
  /** True while the model is downloading / initializing. */
  isLoading: boolean;
  /** True when the model files were already in the browser cache, so
   *  the load is initialisation only — not a download. */
  fromCache: boolean;
  /** 0..1 bytes-progress during model download. 1 before load. */
  loadProgress: number;
  /** Last fatal error (WebGPU unavailable, download failed, …). */
  error: string | null;
  /** Kick off the load. Idempotent — safe to call multiple times. */
  ensureLoaded: () => Promise<void>;
  /** Transcribe a Float32 PCM buffer. The buffer must be mono at
   *  16 kHz (which is what our worklet already produces). */
  transcribe: (audio: Float32Array) => Promise<string>;
}

const _MODEL_ID = "onnx-community/whisper-large-v3-turbo";
/// transformers.js's default `env.cacheKey`.
const _CACHE_NAME = "transformers-cache";

let _pipe: AutomaticSpeechRecognitionPipeline | null = null;
let _loading: Promise<AutomaticSpeechRecognitionPipeline> | null = null;
let _cachedCheck: Promise<boolean> | null = null;
/// Mounted hooks waiting on the shared load, so each can show progress.
const _progressListeners = new Set<(p: number) => void>();

/// Whether the model weights are already in the browser cache.
async function _isCached(): Promise<boolean> {
  try {
    const cache = await caches.open(_CACHE_NAME);
    const keys = await cache.keys();
    return keys.some((r) => r.url.includes(_MODEL_ID) && r.url.includes("encoder_model"));
  } catch {
    return false;
  }
}

async function _load(): Promise<AutomaticSpeechRecognitionPipeline> {
  // WebGPU preflight — transformers.js will fall back to
  // WASM if WebGPU isn't available, but the latency on CPU is
  // unacceptable for live-mode so we hard-fail here.
  if (!("gpu" in navigator)) {
    throw new Error(
      "WebGPU not available in this browser — on-device Whisper requires WebGPU.",
    );
  }
  // Progress reports bytes-per-file. The model is split
  // across several files (encoder, decoder, tokenizer,
  // config, generation config, …) so a naive per-file
  // reading snaps back to zero at every file boundary.
  // Aggregate loaded/total across files so the bar
  // advances monotonically. The first few files report
  // small `total`s before the big weights land; the
  // ratio climbs appropriately once those arrive.
  const fileProgress = new Map<string, { loaded: number; total: number }>();
  return await pipeline(
    "automatic-speech-recognition",
    _MODEL_ID,
    {
      device: "webgpu",
      // fp16 encoder + q4 decoder. fp32 encoder (~800 MB
      // uncompressed) overflows Chrome's single-ArrayBuffer
      // allocation ceiling and the fetch throws RangeError
      // mid-download. fp16 halves it, fits well under the
      // limit, and the quality loss on conversational
      // English is immeasurable at this scale.
      dtype: {
        encoder_model: "fp16",
        decoder_model_merged: "q4",
      },
      progress_callback: (p: unknown) => {
        const prog = p as {
          status?: string;
          file?: string;
          loaded?: number;
          total?: number;
        };
        if (
          (prog.status === "progress" || prog.status === "done")
          && typeof prog.file === "string"
          && typeof prog.loaded === "number"
          && typeof prog.total === "number"
          && prog.total > 0
        ) {
          fileProgress.set(prog.file, { loaded: prog.loaded, total: prog.total });
          let loaded = 0;
          let total = 0;
          for (const { loaded: l, total: t } of fileProgress.values()) {
            loaded += l;
            total += t;
          }
          if (total > 0) {
            const ratio = Math.min(1, loaded / total);
            for (const listener of _progressListeners) listener(ratio);
          }
        }
      },
    },
  );
}

export function useWhisperLocal(): WhisperLocalHandle {
  const [isReady, setIsReady] = useState(() => _pipe !== null);
  const [isLoading, setIsLoading] = useState(false);
  const [fromCache, setFromCache] = useState(false);
  const [loadProgress, setLoadProgress] = useState(() => (_pipe ? 1 : 0));
  const [error, setError] = useState<string | null>(null);
  /// The shared load outlives this component; don't set state after
  /// unmount.
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  const ensureLoaded = useCallback(async () => {
    if (_pipe) {
      setIsReady(true);
      setLoadProgress(1);
      return;
    }
    const onProgress = (p: number) => { if (mounted.current) setLoadProgress(p); };
    _progressListeners.add(onProgress);
    setIsLoading(true);
    setError(null);
    _cachedCheck ??= _isCached();
    void _cachedCheck.then((c) => { if (mounted.current) setFromCache(c); });
    try {
      _loading ??= _load();
      _pipe = await _loading;
      if (mounted.current) {
        setIsReady(true);
        setLoadProgress(1);
      }
    } catch (e) {
      // Let the next attempt retry from scratch.
      _loading = null;
      _cachedCheck = null;
      if (mounted.current) setError(e instanceof Error ? e.message : String(e));
    } finally {
      _progressListeners.delete(onProgress);
      if (mounted.current) setIsLoading(false);
    }
  }, []);

  const transcribe = useCallback(async (audio: Float32Array): Promise<string> => {
    if (!_pipe) await ensureLoaded();
    if (!_pipe) {
      throw new Error(error ?? "Whisper not loaded");
    }
    // chunk_length_s=30 is Whisper's native window; our VAD
    // segments are almost always well under that so this is
    // effectively a single pass per segment.
    const result = await _pipe(audio, {
      language: "english",
      task: "transcribe",
      chunk_length_s: 30,
    });
    const text = Array.isArray(result)
      ? result.map((r) => r.text ?? "").join(" ")
      : (result.text ?? "");
    return text.trim();
  }, [ensureLoaded, error]);

  return { isReady, isLoading, fromCache, loadProgress, error, ensureLoaded, transcribe };
}

/// Decode a base64-encoded WAV (as produced by `useLiveMic`) back
/// into a Float32 PCM buffer suitable for whisper transcription.
/// Assumes 16-bit mono PCM at 16 kHz (matches what we encode).
export function decodeWavBase64ToFloat32(base64: string): Float32Array {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  // Skip the 44-byte RIFF header, then read Int16 little-endian.
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const start = 44;
  const sampleCount = (bytes.length - start) / 2;
  const out = new Float32Array(sampleCount);
  for (let i = 0; i < sampleCount; i++) {
    const s = view.getInt16(start + i * 2, true);
    out[i] = s / 0x8000;
  }
  return out;
}
