import { useCallback, useRef, useState } from "react";

interface QueueItem {
  seq: number;
  data: string;
}

export function useAudioPlayer() {
  const ctxRef = useRef<AudioContext | null>(null);
  const nextTimeRef = useRef(0);
  const queueRef = useRef<QueueItem[]>([]);
  const nextSeqRef = useRef(0);
  const drainingRef = useRef(false);
  const [muted, setMuted] = useState(false);
  const mutedRef = useRef(false);

  // Keep ref in sync with state so callbacks see current value
  const updateMuted = useCallback((value: boolean) => {
    mutedRef.current = value;
    setMuted(value);
  }, []);

  const drainQueue = useCallback(async () => {
    if (drainingRef.current) return;
    drainingRef.current = true;

    try {
      const ctx = ctxRef.current;
      if (!ctx) return;

      while (
        queueRef.current.length > 0 &&
        queueRef.current[0].seq === nextSeqRef.current
      ) {
        const item = queueRef.current.shift()!;
        nextSeqRef.current++;

        // Skip empty chunks (from failed backend synthesis)
        if (!item.data) continue;

        // Decode base64 → ArrayBuffer
        const binary = atob(item.data);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
          bytes[i] = binary.charCodeAt(i);
        }

        // Decode MP3 → AudioBuffer
        const audioBuffer = await ctx.decodeAudioData(bytes.buffer.slice(0));

        // Schedule for gapless playback
        const source = ctx.createBufferSource();
        source.buffer = audioBuffer;
        source.connect(ctx.destination);
        const startTime = Math.max(ctx.currentTime, nextTimeRef.current);
        source.start(startTime);
        nextTimeRef.current = startTime + audioBuffer.duration;
      }
    } catch (e) {
      console.warn("Audio playback error:", e);
    } finally {
      drainingRef.current = false;
    }
  }, []);

  const start = useCallback(() => {
    // Abandon any previous playback
    if (ctxRef.current) {
      ctxRef.current.close().catch(() => {});
      ctxRef.current = null;
    }
    queueRef.current = [];
    nextSeqRef.current = 0;
    nextTimeRef.current = 0;
    drainingRef.current = false;

    if (mutedRef.current) return;
    try {
      ctxRef.current = new AudioContext();
    } catch {
      // AudioContext not available
    }
  }, []);

  const enqueue = useCallback(
    (data: string, sequence: number) => {
      if (mutedRef.current || !ctxRef.current) return;
      queueRef.current.push({ seq: sequence, data });
      queueRef.current.sort((a, b) => a.seq - b.seq);
      drainQueue();
    },
    [drainQueue]
  );

  const done = useCallback(() => {
    // All audio chunks received — drain any remaining
    drainQueue();
  }, [drainQueue]);

  const stop = useCallback(() => {
    // Stop all playback (e.g., when leaving a session)
    if (ctxRef.current) {
      ctxRef.current.close().catch(() => {});
      ctxRef.current = null;
    }
    queueRef.current = [];
    nextSeqRef.current = 0;
    nextTimeRef.current = 0;
  }, []);

  return { start, enqueue, done, stop, muted, setMuted: updateMuted };
}
