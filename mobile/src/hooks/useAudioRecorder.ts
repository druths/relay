import { useCallback, useRef, useState } from "react";
import {
  AudioModule,
  requestRecordingPermissionsAsync,
  setAudioModeAsync,
} from "expo-audio";
import type { AudioRecorder, RecordingInput } from "expo-audio";
import { File } from "expo-file-system";
import * as Haptics from "expo-haptics";

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

  const stopMeteringPoll = useCallback(() => {
    if (meteringIntervalRef.current) {
      clearInterval(meteringIntervalRef.current);
      meteringIntervalRef.current = null;
    }
  }, []);

  const cleanup = useCallback(async () => {
    activeRef.current = false;
    stoppingRef.current = false;
    speechDetectedRef.current = false;
    silenceStartRef.current = null;
    stopMeteringPoll();

    if (recorderRef.current) {
      try {
        if (recorderRef.current.isRecording) {
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
        interruptionMode: "doNotMix",
      }).catch(() => {});
    }

    setRecorderState("idle");
  }, [stopMeteringPoll]);

  const processRecording = useCallback(
    async (recorder: AudioRecorder) => {
      const duration = Date.now() - recordStartRef.current;
      stopMeteringPoll();

      // Stop recording and get the file URI
      let uri: string | null = null;
      try {
        await recorder.stop();
        uri = recorder.uri;
      } catch {
        // Already stopped
        uri = recorder.uri;
      }
      recorderRef.current = null;

      if (!uri || !speechDetectedRef.current || duration < minDuration) {
        console.log(
          `[STT] discarded: ${!uri ? "no uri" : !speechDetectedRef.current ? "no speech" : `too short (${duration}ms)`}`
        );
        if (stoppingRef.current) {
          cleanup();
        } else {
          // Continuous mode: re-enable and restart
          activeRef.current = true;
          startNewRecordingRef.current?.();
        }
        return;
      }

      setRecorderState("processing");
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

      try {
        const recordedFile = new File(uri);
        const base64 = await recordedFile.base64();
        console.log(`[STT] sending recording (${duration}ms) to backend`);
        onCompleteRef.current(base64, "m4a");

        // Clean up temp file
        try {
          recordedFile.delete();
        } catch {}
      } catch (err) {
        console.error("[STT] failed to read recording:", err);
      }

      if (stoppingRef.current) {
        cleanup();
      } else {
        // Continuous mode: re-enable and restart listening
        activeRef.current = true;
        startNewRecordingRef.current?.();
      }
    },
    [cleanup, minDuration, stopMeteringPoll]
  );

  const startNewRecording = useCallback(async () => {
    if (!activeRef.current) return;

    speechDetectedRef.current = false;
    silenceStartRef.current = null;
    setRecorderState("listening");

    try {
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

      await recorder.prepareToRecordAsync();
      if (preferredInputRef.current) {
        try { recorder.setInput(preferredInputRef.current); } catch {}
      }
      recorder.record();
      recorderRef.current = recorder;

      // Poll metering for VAD
      meteringIntervalRef.current = setInterval(() => {
        if (!activeRef.current || !recorderRef.current) {
          stopMeteringPoll();
          return;
        }

        try {
          const status = recorderRef.current.getStatus();
          if (!status.isRecording) return;

          const metering = status.metering ?? -160;

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
              processRecording(recorder);
            }
          }
        } catch {
          // Recorder may have been released
        }
      }, 100);
    } catch (err) {
      console.error("[STT] failed to start recording:", err);
      cleanup();
    }
  }, [cleanup, silenceThresholdDb, silenceTimeout, processRecording, stopMeteringPoll]);

  // Keep ref in sync so processRecording always calls the latest version
  startNewRecordingRef.current = startNewRecording;

  const startListening = useCallback(async () => {
    await cleanup();

    try {
      const { granted } = await requestRecordingPermissionsAsync();
      if (!granted) {
        console.error("[STT] microphone permission denied");
        return;
      }

      await setAudioModeAsync({
        allowsRecording: true,
        playsInSilentMode: true,
        interruptionMode: "doNotMix",
      });

      activeRef.current = true;
      stoppingRef.current = false;
      await startNewRecording();
    } catch (err) {
      console.error("[STT] failed to start listening:", err);
      cleanup();
    }
  }, [cleanup, startNewRecording]);

  const stopListening = useCallback(async () => {
    stoppingRef.current = true;
    activeRef.current = false;
    stopMeteringPoll();

    if (recorderRef.current) {
      const recorder = recorderRef.current;
      if (speechDetectedRef.current) {
        // Has speech — process it
        await processRecording(recorder);
      } else {
        // No speech detected — just clean up
        cleanup();
      }
    } else {
      cleanup();
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
