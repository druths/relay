// AudioWorklet processor that forwards raw PCM frames from the mic
// stream to the main thread, one `process()` quantum at a time.
//
// Why a worklet and not MediaRecorder: MediaRecorder's Opus-in-WebM
// path on Mac/Chrome has intermittent failures where the output
// container holds no audio frames — we hit a 110-byte header-only
// blob despite the mic track being live. The worklet runs in the
// audio rendering thread, pulls samples directly from the mic
// MediaStreamSource, and posts them back as Float32 arrays. We
// then stitch + WAV-encode on the main thread. Opus is cheaper on
// the wire but the reliability is worth the extra bytes.
class PCMRecorderProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._stopped = false;
    this.port.onmessage = (e) => {
      if (e.data === "stop") this._stopped = true;
    };
  }

  process(inputs) {
    if (this._stopped) return false;
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    // Mic is always mono-ish — take channel 0.
    const channel = input[0];
    if (!channel || channel.length === 0) return true;
    // Copy before posting — the underlying buffer is reused each
    // quantum, so a direct reference would be overwritten.
    this.port.postMessage(new Float32Array(channel));
    return true;
  }
}

registerProcessor("pcm-recorder", PCMRecorderProcessor);
