/**
 * Silent audio keepalive — loops a tiny silent WAV to keep the iOS audio
 * session active when the app is backgrounded during conversation mode.
 * Without this, iOS suspends the app during gaps between recorder cycles
 * and TTS playback.
 */
import { createAudioPlayer, AudioPlayer } from "expo-audio";
import { File, Paths } from "expo-file-system";

let player: AudioPlayer | null = null;
let file: File | null = null;

/** Start looping silent audio. No-op if already running. */
export function startKeepAlive() {
  if (player) return;

  const wav = generateSilentWav();
  const f = new File(Paths.cache, "_silent_keepalive.wav");
  f.write(wav);

  const p = createAudioPlayer(f.uri);
  p.loop = true;
  p.volume = 0;
  p.play();

  player = p;
  file = f;
  console.log("[keepalive] started silent audio loop");
}

/** Stop the silent audio loop and clean up. */
export function stopKeepAlive() {
  if (player) {
    player.remove();
    player = null;
    console.log("[keepalive] stopped silent audio loop");
  }
  if (file) {
    try { file.delete(); } catch {}
    file = null;
  }
}

// ── WAV generator ──────────────────────────────────────────────────────
// 0.5s of silence: 16-bit signed PCM, mono, 8 kHz = 8044 bytes total.

function writeString(view: DataView, offset: number, str: string) {
  for (let i = 0; i < str.length; i++) {
    view.setUint8(offset + i, str.charCodeAt(i));
  }
}

function generateSilentWav(): Uint8Array {
  const sampleRate = 8000;
  const numSamples = 4000; // 0.5 seconds
  const bitsPerSample = 16;
  const numChannels = 1;
  const dataSize = numSamples * numChannels * (bitsPerSample / 8);
  const fileSize = 44 + dataSize;

  const buffer = new ArrayBuffer(fileSize);
  const view = new DataView(buffer);

  // RIFF header
  writeString(view, 0, "RIFF");
  view.setUint32(4, fileSize - 8, true);
  writeString(view, 8, "WAVE");

  // fmt chunk
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true); // chunk size
  view.setUint16(20, 1, true); // PCM format
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * numChannels * (bitsPerSample / 8), true);
  view.setUint16(32, numChannels * (bitsPerSample / 8), true);
  view.setUint16(34, bitsPerSample, true);

  // data chunk — audio samples are all zeros (silence), already zeroed by ArrayBuffer
  writeString(view, 36, "data");
  view.setUint32(40, dataSize, true);

  return new Uint8Array(buffer);
}
