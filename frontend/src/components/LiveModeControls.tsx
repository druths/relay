import { useEffect, useMemo, useRef, useState } from "react";
import { useLiveMic } from "../hooks/useLiveMic";
import { useWhisperLocal, decodeWavBase64ToFloat32 } from "../hooks/useWhisperLocal";
import { getLocalSttProvider } from "../utils/localSttSettings";

/// Always-on live-mode indicator. Mirrors the iOS `SoundWaveView`
/// style — a compact 5-bar wave that modulates with the mic
/// meter. Low-key visual, no chip container, no persistent dB
/// readout. Click the wave to toggle a debug line showing state
/// + exact dB (useful when something feels off and you want to see
/// what VAD is thinking without opening DevTools).
///
/// Mute toggle on the right pauses VAD without tearing the session
/// down — subsequent frames are dropped and the wave freezes.
export interface LiveModeControlsProps {
  /** Called when a VAD segment should be sent as audio to the
   *  backend (cloud STT path). */
  onCapture: (data: string, format: string) => void;
  /** Called when a VAD segment has already been transcribed on
   *  device (local Whisper path). Caller sends it as a normal
   *  text_input. */
  onLocalText?: (text: string) => void;
  /** Fires when the VAD confirms a speech attack during an agent's
   *  TTS reply. Call `sendInterrupt` so the agent stops talking
   *  and the user's turn supersedes. */
  onBargeIn?: () => void;
  disabled?: boolean;
}

export function LiveModeControls({
  onCapture, onLocalText, onBargeIn, disabled,
}: LiveModeControlsProps) {
  const mic = useLiveMic();
  const whisper = useWhisperLocal();
  const [showDebug, setShowDebug] = useState(false);
  const useLocalWhisper = getLocalSttProvider() === "whisper";

  // Stable refs so the one-shot mount effect below sees current
  // callbacks without re-running on every parent render.
  const captureRef = useRef(onCapture);
  captureRef.current = onCapture;
  const localTextRef = useRef(onLocalText);
  localTextRef.current = onLocalText;
  const bargeInRef = useRef(onBargeIn);
  bargeInRef.current = onBargeIn;
  const whisperRef = useRef(whisper);
  whisperRef.current = whisper;

  // Kick off model load eagerly when local Whisper is the
  // configured provider — the first-use download is big, so start
  // it as soon as live mode is engaged rather than waiting for the
  // first segment.
  useEffect(() => {
    if (useLocalWhisper) {
      void whisper.ensureLoaded();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [useLocalWhisper]);

  useEffect(() => {
    void mic.start({
      onSegment: async (data, format) => {
        if (useLocalWhisper) {
          try {
            const audio = decodeWavBase64ToFloat32(data);
            const text = await whisperRef.current.transcribe(audio);
            if (text.trim()) localTextRef.current?.(text);
          } catch (e) {
            console.warn("[whisper] transcribe failed, falling back to cloud:", e);
            captureRef.current(data, format);
          }
        } else {
          captureRef.current(data, format);
        }
      },
      onSpeechStarted: () => bargeInRef.current?.(),
    });
    return () => mic.stop();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // While local Whisper is loading or errored, we take over the
  // whole bar with a dedicated progress / error view rather than
  // hiding the state behind the (collapsed-by-default) debug line.
  // The one-time ~400 MB download is slow enough that users deserve
  // an obvious signal.
  const whisperBlocking = useLocalWhisper && !whisper.isReady;

  const stateLabel = disabled
    ? "Not connected"
    : mic.muted
      ? "Muted"
      : mic.speechDetected
        ? "Speaking…"
        : "Listening";

  if (whisperBlocking) {
    const pct = Math.round(whisper.loadProgress * 100);
    return (
      <div className="flex items-center gap-3 pl-5 pr-4 py-2">
        <div className="flex-1 min-w-0">
          <div className="flex items-center justify-between text-[11px] font-mono mb-1">
            <span className="text-gray-300">
              {whisper.error
                ? "Whisper couldn't load"
                : whisper.isLoading
                  ? "Downloading on-device Whisper (one-time)"
                  : "Starting Whisper…"}
            </span>
            {!whisper.error && (
              <span className="text-gray-500">{pct}%</span>
            )}
          </div>
          <div className="h-1.5 bg-gray-800 rounded overflow-hidden">
            <div
              className={
                whisper.error
                  ? "h-full bg-red-500/70"
                  : "h-full bg-emerald-500 transition-[width] duration-150"
              }
              style={{
                width: whisper.error
                  ? "100%"
                  : `${pct}%`,
              }}
            />
          </div>
          {whisper.error && (
            <div className="text-[10px] font-mono text-red-400 mt-1 truncate">
              {whisper.error}
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <div
      // `pl-5` instead of `px-4` so the wave bars' center sits over
      // the mic-toggle chip below. TextInput has `p-4` + its leading
      // chip is `px-3` h-9, so the chip's center is at ~36px from
      // the input bar's left edge; the wave is 32px wide, so a
      // 20px left padding puts its center at the same ~36px.
      className="flex items-center gap-3 pl-5 pr-4 py-1"
    >
      <button
        type="button"
        onClick={() => setShowDebug((v) => !v)}
        title="Toggle live-mode debug info"
        aria-label="Toggle live-mode debug info"
        className="focus:outline-none cursor-pointer"
      >
        <SoundWave
          level={mic.meteringLevel}
          active={!mic.muted && !disabled}
          speaking={mic.speechDetected}
        />
      </button>
      {showDebug && (
        <span className="text-[11px] font-mono text-gray-500 whitespace-nowrap">
          {stateLabel} · {mic.meteringLevel.toFixed(0)} dB
        </span>
      )}
      <div className="flex-1" />
      <button
        type="button"
        onClick={() => mic.setMuted(!mic.muted)}
        disabled={disabled}
        aria-pressed={mic.muted}
        title={mic.muted ? "Unmute mic" : "Mute mic"}
        className={
          "shrink-0 w-7 h-7 rounded-full flex items-center justify-center transition-colors " +
          (mic.muted
            ? "text-red-400 hover:bg-gray-800"
            : "text-gray-500 hover:text-gray-300 hover:bg-gray-800") +
          (disabled ? " opacity-40 cursor-not-allowed" : " cursor-pointer")
        }
      >
        {mic.muted ? (
          <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
            <path fillRule="evenodd" d="M3.28 2.22a.75.75 0 00-1.06 1.06l14.5 14.5a.75.75 0 101.06-1.06l-2.3-2.3A6.98 6.98 0 0016 9.5a.75.75 0 00-1.5 0 5.5 5.5 0 01-.72 2.72l-1.09-1.1A3 3 0 0013 9V4a3 3 0 00-5.9-.78L3.28 2.22zm3.59 5.72L13 14.06v.19a3 3 0 01-4.47 2.61l-1.14 1.14a4.5 4.5 0 002.11.95V18.5a.75.75 0 001.5 0v-1.56A5.5 5.5 0 0014.5 14l1.03 1.03a7 7 0 01-5.03 2.42V17a7 7 0 01-6.49-4.3L4.6 13.6a5.5 5.5 0 002.27 2.74v-.95L4.5 13.03a.75.75 0 00-1.06 0 .75.75 0 000 1.06A7 7 0 0010 18.5a7 7 0 001.69-.2L6.87 7.95z" clipRule="evenodd"/>
          </svg>
        ) : (
          <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 20 20" fill="currentColor">
            <path d="M7 4a3 3 0 016 0v5a3 3 0 11-6 0V4z"/>
            <path d="M5.5 9.5a.75.75 0 00-1.5 0 6 6 0 005.25 5.95V17H7a.75.75 0 000 1.5h6a.75.75 0 000-1.5h-2.25v-1.55A6 6 0 0016 9.5a.75.75 0 00-1.5 0 4.5 4.5 0 11-9 0z"/>
        </svg>
        )}
      </button>
    </div>
  );
}

/// Compact 5-bar sound wave. Each bar's height tracks the mic
/// meter with a small per-bar random offset re-rolled whenever the
/// level changes — gives a subtle "alive" wiggle that reads as
/// mic signal instead of a static block. Port of iOS's
/// `SoundWaveView`.
function SoundWave({
  level, active, speaking,
}: {
  level: number;
  active: boolean;
  speaking: boolean;
}) {
  const barCount = 5;
  // Map -60..0 dB → 0..1, clamp.
  const normalized = Math.max(0, Math.min(1, (level + 60) / 60));
  // Reshuffle the per-bar offsets whenever the level changes so the
  // bars pulse slightly off-sync — same trick iOS uses. useMemo
  // keyed on `level` so successive silent frames don't thrash the
  // render.
  const offsets = useMemo(
    () => Array.from({ length: barCount }, () => Math.random() * 0.6 - 0.3),
    [level],
  );
  const color = !active
    ? "bg-gray-600"
    : speaking
      ? "bg-red-400"
      : "bg-emerald-500/80";
  return (
    <div className="flex items-end gap-[3px] h-9">
      {offsets.map((off, i) => {
        const bl = Math.max(0.08, Math.min(1, normalized + off * normalized));
        const h = 4 + bl * 28;
        return (
          <div
            key={i}
            className={`w-1 rounded-sm ${color} transition-[height] duration-100`}
            style={{ height: `${h}px` }}
          />
        );
      })}
    </div>
  );
}
