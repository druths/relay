/**
 * Short audio chime for confirming user actions (e.g. text submitted).
 * Generates a tiny WAV in-memory and plays it via expo-audio.
 */
import { createAudioPlayer } from "expo-audio";
import { File, Paths } from "expo-file-system";

const SAMPLE_RATE = 22050;

/** Generate a calm, low blip — matches the web's playTranscriptionEarcon. */
function generateChimeWav(): Uint8Array {
  const duration = 0.1; // seconds
  const freq = 280;
  const numSamples = Math.floor(SAMPLE_RATE * duration);
  const dataSize = numSamples * 2; // 16-bit mono
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);

  // WAV header
  const writeStr = (offset: number, str: string) => {
    for (let i = 0; i < str.length; i++) view.setUint8(offset + i, str.charCodeAt(i));
  };
  writeStr(0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeStr(8, "WAVE");
  writeStr(12, "fmt ");
  view.setUint32(16, 16, true); // chunk size
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, SAMPLE_RATE, true);
  view.setUint32(28, SAMPLE_RATE * 2, true); // byte rate
  view.setUint16(32, 2, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  writeStr(36, "data");
  view.setUint32(40, dataSize, true);

  // Generate sine wave with fade-in/fade-out envelope
  for (let i = 0; i < numSamples; i++) {
    const t = i / SAMPLE_RATE;
    const sine = Math.sin(2 * Math.PI * freq * t);

    // Envelope: quick fade-in (30ms), then fade-out
    let envelope: number;
    if (t < 0.03) {
      envelope = t / 0.03; // fade in
    } else {
      envelope = Math.exp(-10 * (t - 0.03)); // exponential decay
    }

    const amplitude = 0.08;
    const sample = Math.max(-1, Math.min(1, sine * envelope * amplitude));
    view.setInt16(44 + i * 2, sample * 32767, true);
  }

  return new Uint8Array(buffer);
}

let chimeBytes: Uint8Array | null = null;

export function playChime(): void {
  try {
    if (!chimeBytes) {
      chimeBytes = generateChimeWav();
    }
    const file = new File(Paths.cache, "relay_chime.wav");
    file.write(chimeBytes);
    const player = createAudioPlayer(file.uri);
    player.play();
    // Clean up after playback
    setTimeout(() => {
      player.remove();
      file.delete();
    }, 500);
  } catch {
    // Audio not available
  }
}
