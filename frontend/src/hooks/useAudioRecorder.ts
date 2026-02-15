import { useCallback, useRef, useState } from "react";

export type RecorderState = "idle" | "listening" | "recording" | "processing";

interface UseAudioRecorderOptions {
  /** Called with base64-encoded audio when recording completes */
  onRecordingComplete: (audioBase64: string, format: string) => void;
  /** Volume threshold (0-255 from AnalyserNode) to detect speech. Default 35. */
  silenceThreshold?: number;
  /** Milliseconds of silence before stopping. Default 500. */
  silenceTimeout?: number;
  /** Minimum recording duration in ms. Shorter recordings are discarded. Default 400. */
  minDuration?: number;
}

export function useAudioRecorder({
  onRecordingComplete,
  silenceThreshold = 35,
  silenceTimeout = 500,
  minDuration = 400,
}: UseAudioRecorderOptions) {
  const [recorderState, setRecorderState] = useState<RecorderState>("idle");

  const streamRef = useRef<MediaStream | null>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const silenceStartRef = useRef<number | null>(null);
  const rafRef = useRef<number>(0);
  const activeRef = useRef(false);
  const stoppingRef = useRef(false); // true when user manually clicks stop
  const recordStartRef = useRef<number>(0);
  const onCompleteRef = useRef(onRecordingComplete);
  onCompleteRef.current = onRecordingComplete;

  const cleanup = useCallback(() => {
    activeRef.current = false;
    stoppingRef.current = false;
    cancelAnimationFrame(rafRef.current);

    if (
      mediaRecorderRef.current &&
      mediaRecorderRef.current.state === "recording"
    ) {
      mediaRecorderRef.current.stop();
    }
    mediaRecorderRef.current = null;

    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;

    audioCtxRef.current?.close().catch(() => {});
    audioCtxRef.current = null;
    analyserRef.current = null;

    chunksRef.current = [];
    silenceStartRef.current = null;
    setRecorderState("idle");
  }, []);

  /** Start a new VAD loop using the existing stream/analyser. */
  const startVADLoop = useCallback(
    (analyser: AnalyserNode, stream: MediaStream) => {
      const mediaRecorder = new MediaRecorder(stream, {
        mimeType: "audio/webm;codecs=opus",
      });
      mediaRecorderRef.current = mediaRecorder;
      chunksRef.current = [];

      mediaRecorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };

      mediaRecorder.onstop = async () => {
        const chunks = chunksRef.current;
        chunksRef.current = [];
        const duration = Date.now() - recordStartRef.current;

        console.log(`[STT] onstop: ${chunks.length} chunks, ${duration}ms duration, stopping=${stoppingRef.current}`);

        if (chunks.length === 0 || duration < minDuration) {
          console.log(`[STT] discarded: ${chunks.length === 0 ? "no chunks" : `too short (${duration}ms < ${minDuration}ms)`}`);
          if (stoppingRef.current) {
            cleanup();
          } else if (streamRef.current && analyserRef.current) {
            setRecorderState("listening");
            startVADLoop(analyserRef.current, streamRef.current);
          }
          return;
        }

        setRecorderState("processing");

        const blob = new Blob(chunks, { type: "audio/webm" });
        console.log(`[STT] sending ${blob.size} bytes to backend`);
        const buffer = await blob.arrayBuffer();
        const bytes = new Uint8Array(buffer);
        let binary = "";
        for (let i = 0; i < bytes.length; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        const base64 = btoa(binary);

        onCompleteRef.current(base64, "webm");

        // If user manually stopped, tear down everything
        if (stoppingRef.current) {
          cleanup();
          return;
        }

        // Continuous mode: restart VAD on the same stream
        if (streamRef.current && analyserRef.current) {
          setRecorderState("listening");
          startVADLoop(analyserRef.current, streamRef.current);
        } else {
          cleanup();
        }
      };

      activeRef.current = true;

      const dataArray = new Uint8Array(analyser.frequencyBinCount);
      let isRecording = false;
      let logCounter = 0;

      const checkVolume = () => {
        if (!activeRef.current) return;

        analyser.getByteFrequencyData(dataArray);
        const avg =
          dataArray.reduce((sum, val) => sum + val, 0) / dataArray.length;

        // Log volume every ~60 frames (~1 second)
        if (logCounter++ % 60 === 0) {
          console.log(`[STT] volume: ${avg.toFixed(1)} (threshold: ${silenceThreshold}, recording: ${isRecording})`);
        }

        if (avg > silenceThreshold) {
          silenceStartRef.current = null;
          if (!isRecording) {
            console.log(`[STT] speech detected (avg=${avg.toFixed(1)}), starting recording`);
            isRecording = true;
            recordStartRef.current = Date.now();
            mediaRecorder.start(100);
            setRecorderState("recording");
          }
        } else if (isRecording) {
          if (silenceStartRef.current === null) {
            silenceStartRef.current = Date.now();
          } else if (Date.now() - silenceStartRef.current > silenceTimeout) {
            console.log(`[STT] silence timeout (${silenceTimeout}ms), stopping recording`);
            activeRef.current = false;
            silenceStartRef.current = null;
            mediaRecorder.stop();
            return;
          }
        }

        rafRef.current = requestAnimationFrame(checkVolume);
      };

      rafRef.current = requestAnimationFrame(checkVolume);
    },
    [cleanup, silenceThreshold, silenceTimeout, minDuration]
  );

  const startListening = useCallback(async () => {
    cleanup();

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true },
      });
      streamRef.current = stream;

      const audioCtx = new AudioContext();
      audioCtxRef.current = audioCtx;
      const source = audioCtx.createMediaStreamSource(stream);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 256;
      source.connect(analyser);
      analyserRef.current = analyser;

      stoppingRef.current = false;
      setRecorderState("listening");
      startVADLoop(analyser, stream);
    } catch (err) {
      console.error("Microphone access failed:", err);
      cleanup();
    }
  }, [cleanup, startVADLoop]);

  const stopListening = useCallback(() => {
    stoppingRef.current = true;
    activeRef.current = false;
    cancelAnimationFrame(rafRef.current);

    if (
      mediaRecorderRef.current &&
      mediaRecorderRef.current.state === "recording"
    ) {
      // Stop recording — onstop will send the audio then clean up
      mediaRecorderRef.current.stop();
    } else {
      // Was listening but no speech detected — just clean up
      cleanup();
    }
  }, [cleanup]);

  return {
    recorderState,
    startListening,
    stopListening,
  };
}
