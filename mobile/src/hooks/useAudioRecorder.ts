import { useCallback, useRef, useState } from "react";
import {
  AudioModule,
  requestRecordingPermissionsAsync,
  setAudioModeAsync,
} from "expo-audio";
import type { AudioRecorder, RecordingInput } from "expo-audio";
import { File } from "expo-file-system";
import * as Haptics from "expo-haptics";
import { startKeepAlive, stopKeepAlive } from "../silentKeepAlive";

export type RecorderState = "idle" | "listening" | "recording" | "processing";

interface UseAudioRecorderOptions {
  /** Called with base64-encoded audio when recording completes */
  onRecordingComplete: (audioBase64: string, format: string) => void;
  /** When true, keep allowsRecording=true after cleanup (earpiece mode). */
  earpieceMode?: boolean;
  /** Metering threshold in dB (typically -160 to 0). Default -35. */
  silenceThresholdDb?: number;
  /** Milliseconds of silence before stopping. Default 500. */
  silenceTimeout?: number;
  /** Minimum recording duration in ms. Shorter recordings are discarded. Default 400. */
  minDuration?: number;
}

export function useAudioRecorder({
  onRecordingComplete,
  earpieceMode = false,
  silenceThresholdDb = -35,
  silenceTimeout = 500,
  minDuration = 400,
}: UseAudioRecorderOptions) {
  const [recorderState, setRecorderState] = useState<RecorderState>("idle");

  const recorderRef = useRef<AudioRecorder | null>(null);
  const meteringIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const silenceStartRef = useRef<number | null>(null);
  const activeRef = useRef(false);
  const stoppingRef = useRef(false);
  const recordStartRef = useRef<number>(0);
  const speechDetectedRef = useRef(false);
  const onCompleteRef = useRef(onRecordingComplete);
  onCompleteRef.current = onRecordingComplete;
  const earpieceModeRef = useRef(earpieceMode);
  earpieceModeRef.current = earpieceMode;

  // Ref so processRecording can call startNewRecording without circular dependency
  const startNewRecordingRef = useRef<(() => Promise<void>) | undefined>(undefined);
  const preferredInputRef = useRef<string | null>(null);

  // Concurrency guards (1A, 1D)
  const processingRef = useRef(false);
  const startingRef = useRef(false);

  const stopMeteringPoll = useCallback(() => {
    if (meteringIntervalRef.current) {
      clearInterval(meteringIntervalRef.current);
      meteringIntervalRef.current = null;
    }
  }, []);

  const cleanup = useCallback(async () => {
    console.log("[STT][lifecycle] cleanup called");
    activeRef.current = false;
    stoppingRef.current = false;
    speechDetectedRef.current = false;
    silenceStartRef.current = null;
    processingRef.current = false;
    startingRef.current = false;
    stopMeteringPoll();
    stopKeepAlive();

    if (recorderRef.current) {
      try {
        const wasRecording = recorderRef.current.isRecording;
        console.log(`[STT][lifecycle] cleanup: stopping recorder (wasRecording=${wasRecording})`);
        if (wasRecording) {
          await recorderRef.current.stop();
        }
      } catch {
        // Already stopped
      }
      recorderRef.current = null;
    }

    // In speaker mode, switch back to playback-only so audio routes
    // through the speaker. In earpiece mode, keep allowsRecording=true.
    if (!earpieceModeRef.current) {
      setAudioModeAsync({
        allowsRecording: false,
        playsInSilentMode: true,
        shouldPlayInBackground: true,
        interruptionMode: "doNotMix",
      }).catch(() => {});
    }

    setRecorderState("idle");
    console.log("[STT][lifecycle] cleanup done → idle");
  }, [stopMeteringPoll]);

  const processRecording = useCallback(
    async (recorder: AudioRecorder) => {
      // 1A: Guard against re-entrant calls
      if (processingRef.current) {
        console.log("[STT][lifecycle] processRecording: already processing, skipping");
        return;
      }
      processingRef.current = true;

      const duration = Date.now() - recordStartRef.current;
      console.log(`[STT][lifecycle] processRecording called (duration=${duration}ms, stopping=${stoppingRef.current})`);
      stopMeteringPoll();

      // Stop recording and get the file URI
      let uri: string | null = null;
      try {
        await recorder.stop();
        uri = recorder.uri;
        console.log(`[STT][lifecycle] recorder stopped, uri=${uri ? "yes" : "null"}`);
      } catch (e) {
        // Already stopped
        uri = recorder.uri;
        console.log(`[STT][lifecycle] recorder.stop() threw (already stopped?), uri=${uri ? "yes" : "null"}`, e);
      }
      recorderRef.current = null;

      if (!uri || !speechDetectedRef.current || duration < minDuration) {
        console.log(
          `[STT] discarded: ${!uri ? "no uri" : !speechDetectedRef.current ? "no speech" : `too short (${duration}ms)`}`
        );
        // 1B: Clear guard before branching to restart or cleanup
        processingRef.current = false;
        if (stoppingRef.current) {
          console.log("[STT][lifecycle] discarded + stopping → cleanup");
          cleanup();
        } else {
          // Continuous mode: re-enable and restart
          console.log("[STT][lifecycle] discarded + continuous → restarting");
          activeRef.current = true;
          startNewRecordingRef.current?.().catch((e: unknown) => {
            console.error("[STT] restart after discard failed:", e);
            cleanup();
          });
        }
        return;
      }

      setRecorderState("processing");
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

      try {
        const recordedFile = new File(uri);
        const base64 = await recordedFile.base64();
        console.log(`[STT][lifecycle] sending recording (${duration}ms, ${base64.length} b64 chars) to backend`);
        onCompleteRef.current(base64, "m4a");

        // Clean up temp file
        try {
          recordedFile.delete();
        } catch {}
      } catch (err) {
        console.error("[STT] failed to read recording:", err);
      }

      // 1B: Clear guard before branching to restart or cleanup
      processingRef.current = false;
      if (stoppingRef.current) {
        console.log("[STT][lifecycle] processed + stopping → cleanup");
        cleanup();
      } else {
        // Continuous mode: re-enable and restart listening
        console.log("[STT][lifecycle] processed + continuous → restarting");
        activeRef.current = true;
        startNewRecordingRef.current?.().catch((e: unknown) => {
          console.error("[STT] restart after processing failed:", e);
          cleanup();
        });
      }
    },
    [cleanup, minDuration, stopMeteringPoll]
  );

  // Counter for periodic health-check logging in metering poll
  const meteringTickRef = useRef(0);
  // Dead-input detection: counts consecutive ticks with metering ≤ -100 dB.
  // TTS playback can silently kill the iOS audio input — the recorder reports
  // isRecording=true but metering is pegged at ~-120 dB (digital silence).
  // Real ambient silence is typically -40 to -60 dB, so anything below -100 dB
  // for more than ~0.5 s means the input is dead and we need to cycle.
  const deadInputTicksRef = useRef(0);
  const DEAD_INPUT_THRESHOLD = -100; // dB
  const DEAD_INPUT_TICKS = 5; // 0.5 seconds at 100ms — just enough to confirm

  const startNewRecording = useCallback(async () => {
    // 1D: Guard against concurrent starts
    console.log(`[STT][lifecycle] startNewRecording called (active=${activeRef.current}, starting=${startingRef.current})`);
    if (!activeRef.current) {
      console.log("[STT][lifecycle] startNewRecording: bailing — activeRef is false");
      return;
    }
    if (startingRef.current) {
      console.log("[STT][lifecycle] startNewRecording: bailing — already starting");
      return;
    }
    startingRef.current = true;

    speechDetectedRef.current = false;
    silenceStartRef.current = null;
    meteringTickRef.current = 0;
    deadInputTicksRef.current = 0;
    setRecorderState("listening");

    try {
      // Re-establish audio session for recording each time — iOS may have
      // reconfigured the session after TTS playback or recorder.stop().
      console.log("[STT][lifecycle] setAudioModeAsync({ allowsRecording: true })");
      await setAudioModeAsync({
        allowsRecording: true,
        playsInSilentMode: true,
        shouldPlayInBackground: true,
        interruptionMode: "doNotMix",
      });
      console.log("[STT][lifecycle] audio mode set OK");

      const recorder = new AudioModule.AudioRecorder({
        isMeteringEnabled: true,
        extension: ".m4a",
        sampleRate: 44100,
        numberOfChannels: 1,
        bitRate: 128000,
        android: {
          outputFormat: "mpeg4",
          audioEncoder: "aac",
        },
        ios: {
          audioQuality: 96, // MAX
        },
        web: {},
      });

      console.log("[STT][lifecycle] recorder created, preparing...");
      await recorder.prepareToRecordAsync();
      console.log("[STT][lifecycle] recorder prepared");
      if (preferredInputRef.current) {
        try { recorder.setInput(preferredInputRef.current); } catch {}
      }
      recorder.record();
      recorderRef.current = recorder;
      console.log("[STT][lifecycle] recorder.record() called — now polling metering");

      // Poll metering for VAD
      meteringIntervalRef.current = setInterval(() => {
        // 1E: Snapshot ref into local to prevent null-after-guard races
        const currentRecorder = recorderRef.current;
        if (!activeRef.current || !currentRecorder) {
          console.log(`[STT][poll] guard failed: active=${activeRef.current}, recorder=${!!currentRecorder} → stopping poll`);
          stopMeteringPoll();
          return;
        }

        try {
          const status = currentRecorder.getStatus();
          meteringTickRef.current++;

          // Log a health-check every ~2 seconds (20 ticks at 100ms)
          if (meteringTickRef.current % 20 === 0) {
            console.log(
              `[STT][health] tick=${meteringTickRef.current} isRecording=${status.isRecording} ` +
              `metering=${(status.metering ?? -160).toFixed(1)}dB speech=${speechDetectedRef.current} ` +
              `active=${activeRef.current}`
            );
          }

          if (!status.isRecording) {
            // Log only once when we first notice it's not recording
            if (meteringTickRef.current === 1 || meteringTickRef.current % 20 === 1) {
              console.log(`[STT][poll] status.isRecording=false at tick=${meteringTickRef.current}`);
            }
            return;
          }

          const metering = status.metering ?? -160;

          // Dead-input detection: iOS killed our mic input (TTS playback
          // reconfigured the audio session). Metering stuck ≤ -100 dB.
          if (!speechDetectedRef.current && metering <= DEAD_INPUT_THRESHOLD) {
            deadInputTicksRef.current++;
            if (deadInputTicksRef.current >= DEAD_INPUT_TICKS) {
              console.log(
                `[STT][dead-input] metering stuck at ${metering.toFixed(1)}dB for ${deadInputTicksRef.current} ticks — cycling recorder`
              );
              stopMeteringPoll();
              // 1C: Properly sequence stop → restart via async IIFE
              const deadRecorder = currentRecorder;
              recorderRef.current = null;
              activeRef.current = false; // prevent re-entry from stale ticks

              (async () => {
                try { await deadRecorder.stop(); } catch {}
                activeRef.current = true;
                startNewRecordingRef.current?.().catch((e: unknown) => {
                  console.error("[STT] restart after dead-input failed:", e);
                  cleanup();
                });
              })();
              return;
            }
          } else {
            deadInputTicksRef.current = 0;
          }

          if (metering > silenceThresholdDb) {
            // Sound detected
            silenceStartRef.current = null;
            if (!speechDetectedRef.current) {
              console.log(
                `[STT] speech detected (metering=${metering.toFixed(1)}dB)`
              );
              speechDetectedRef.current = true;
              recordStartRef.current = Date.now();
              setRecorderState("recording");
            }
          } else if (speechDetectedRef.current) {
            // Silence after speech
            if (silenceStartRef.current === null) {
              silenceStartRef.current = Date.now();
            } else if (Date.now() - silenceStartRef.current > silenceTimeout) {
              console.log(`[STT] silence timeout, processing recording`);
              // Temporarily disable to prevent re-entry
              activeRef.current = false;
              // 1A: Check guard before calling processRecording
              if (!processingRef.current) {
                processRecording(currentRecorder);
              }
            }
          }
        } catch (e) {
          console.warn("[STT][poll] metering error:", e);
        }
      }, 100);
    } catch (err) {
      console.error("[STT] failed to start recording:", err);
      cleanup();
    } finally {
      startingRef.current = false;
    }
  }, [cleanup, silenceThresholdDb, silenceTimeout, processRecording, stopMeteringPoll]);

  // Keep ref in sync so processRecording always calls the latest version
  startNewRecordingRef.current = startNewRecording;

  const startListening = useCallback(async () => {
    console.log("[STT][lifecycle] startListening called");
    await cleanup();

    try {
      const { granted } = await requestRecordingPermissionsAsync();
      if (!granted) {
        console.error("[STT] microphone permission denied");
        return;
      }

      console.log("[STT][lifecycle] startListening: initial setAudioModeAsync");
      await setAudioModeAsync({
        allowsRecording: true,
        playsInSilentMode: true,
        shouldPlayInBackground: true,
        interruptionMode: "doNotMix",
      });

      activeRef.current = true;
      stoppingRef.current = false;
      startKeepAlive();
      console.log("[STT][lifecycle] startListening → startNewRecording");
      await startNewRecording();
    } catch (err) {
      console.error("[STT] failed to start listening:", err);
      cleanup();
    }
  }, [cleanup, startNewRecording]);

  const stopListening = useCallback(async () => {
    console.log(`[STT][lifecycle] stopListening called (speech=${speechDetectedRef.current}, recorder=${!!recorderRef.current})`);
    stoppingRef.current = true;
    activeRef.current = false;
    stopMeteringPoll();

    if (recorderRef.current) {
      const recorder = recorderRef.current;
      if (speechDetectedRef.current) {
        // Has speech — process it
        console.log("[STT][lifecycle] stopListening: has speech → processRecording");
        await processRecording(recorder);
      } else {
        // No speech detected — just clean up
        console.log("[STT][lifecycle] stopListening: no speech → cleanup");
        await cleanup();
      }
    } else {
      console.log("[STT][lifecycle] stopListening: no recorder → cleanup");
      await cleanup();
    }
  }, [cleanup, processRecording, stopMeteringPoll]);

  const getAvailableInputs = useCallback(async (): Promise<RecordingInput[]> => {
    if (recorderRef.current) {
      return recorderRef.current.getAvailableInputs();
    }
    // Create a temporary recorder to enumerate devices
    try {
      const { granted } = await requestRecordingPermissionsAsync();
      if (!granted) return [];
      await setAudioModeAsync({
        allowsRecording: true,
        playsInSilentMode: true,
        shouldPlayInBackground: true,
        interruptionMode: "doNotMix",
      });
      const temp = new AudioModule.AudioRecorder({
        extension: ".m4a",
        sampleRate: 44100,
        numberOfChannels: 1,
        bitRate: 128000,
        android: { outputFormat: "mpeg4", audioEncoder: "aac" },
        ios: { audioQuality: 96 },
        web: {},
      });
      await temp.prepareToRecordAsync();
      const inputs = temp.getAvailableInputs();
      try { await temp.stop(); } catch {}
      if (!earpieceModeRef.current) {
        setAudioModeAsync({
          allowsRecording: false,
          playsInSilentMode: true,
          shouldPlayInBackground: true,
          interruptionMode: "doNotMix",
        }).catch(() => {});
      }
      return inputs;
    } catch (err) {
      console.error("[STT] failed to enumerate inputs:", err);
      return [];
    }
  }, []);

  const getCurrentInput = useCallback(async (): Promise<RecordingInput | null> => {
    if (!recorderRef.current) return null;
    try {
      return await recorderRef.current.getCurrentInput();
    } catch {
      return null;
    }
  }, []);

  const setInput = useCallback((uid: string) => {
    preferredInputRef.current = uid;
    if (recorderRef.current) {
      try { recorderRef.current.setInput(uid); } catch {}
    }
  }, []);

  return {
    recorderState,
    startListening,
    stopListening,
    getAvailableInputs,
    getCurrentInput,
    setInput,
  };
}

export type { RecordingInput };
