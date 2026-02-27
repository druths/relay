import { useCallback, useRef, useState } from "react";
import { createAudioPlayer, AudioPlayer } from "expo-audio";
import type { AudioStatus } from "expo-audio";
import { File, Paths } from "expo-file-system";

interface QueueItem {
  seq: number;
  data: string; // base64 MP3
}

interface PreparedChunk {
  player: AudioPlayer;
  file: File;
  loaded: Promise<void>;
}

// 2A: Timeout wrapper — prevents hanging on stuck promises
function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label}: timed out after ${ms}ms`)), ms);
    promise.then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); },
    );
  });
}

function prepareChunk(item: QueueItem): PreparedChunk {
  const file = new File(Paths.cache, `relay_tts_${item.seq}.mp3`);
  const binaryStr = atob(item.data);
  const bytes = new Uint8Array(binaryStr.length);
  for (let i = 0; i < binaryStr.length; i++) {
    bytes[i] = binaryStr.charCodeAt(i);
  }
  file.write(bytes);
  const player = createAudioPlayer(file.uri);

  // 2B: Wrap loaded promise with 5s timeout
  const loaded = withTimeout(
    new Promise<void>((resolve) => {
      if (player.isLoaded) { resolve(); return; }
      const sub = player.addListener("playbackStatusUpdate", (status: AudioStatus) => {
        if (status.isLoaded) {
          sub.remove();
          resolve();
        }
      });
    }),
    5000,
    `prepareChunk(seq=${item.seq})`,
  );

  return { player, file, loaded };
}

function waitForFinish(player: AudioPlayer): Promise<void> {
  return new Promise((resolve) => {
    const sub = player.addListener("playbackStatusUpdate", (status: AudioStatus) => {
      if (status.didJustFinish) {
        sub.remove();
        resolve();
      }
    });
  });
}

export function useAudioPlayer() {
  const queueRef = useRef<QueueItem[]>([]);
  const nextSeqRef = useRef(0);
  const drainingRef = useRef(false);
  const activeRef = useRef(false);
  const playersRef = useRef<AudioPlayer[]>([]);
  const [muted, setMuted] = useState(false);
  const mutedRef = useRef(false);

  // Pending stream: when a new audio_start arrives while current audio is
  // still playing, we buffer incoming chunks here and play them after the
  // current stream finishes instead of cutting it off.
  const pendingResetRef = useRef(false);
  const pendingQueueRef = useRef<QueueItem[]>([]);

  const updateMuted = useCallback((value: boolean) => {
    mutedRef.current = value;
    setMuted(value);
  }, []);

  const drainQueue = useCallback(async () => {
    if (drainingRef.current) return;
    drainingRef.current = true;
    console.log(`[TTS] drainQueue: starting (queue=${queueRef.current.length}, nextSeq=${nextSeqRef.current})`);

    let prepared: PreparedChunk | null = null;

    try {
      while (
        activeRef.current &&
        queueRef.current.length > 0 &&
        queueRef.current[0].seq === nextSeqRef.current
      ) {
        const item = queueRef.current.shift()!;
        nextSeqRef.current++;

        // Use pre-prepared chunk or prepare now
        const current = prepared ?? prepareChunk(item);
        prepared = null;
        playersRef.current.push(current.player);

        await current.loaded;

        // 2E: Recheck muted state before playing
        if (mutedRef.current || !activeRef.current) {
          console.log("[TTS] drainQueue: muted or stopped before play — skipping remaining");
          current.player.remove();
          playersRef.current = playersRef.current.filter((p) => p !== current.player);
          try { current.file.delete(); } catch {}
          activeRef.current = false;
          queueRef.current = [];
          break;
        }

        // 2C: Set up finish listener with 30s timeout to prevent infinite hang
        const finished = withTimeout(
          waitForFinish(current.player),
          30000,
          `waitForFinish(seq=${item.seq})`,
        );
        current.player.play();
        console.log(`[TTS] drainQueue: playing seq=${item.seq}`);

        // While playing, pre-prepare the next chunk so it's ready instantly
        let nextReady: PreparedChunk | null = null;
        if (
          activeRef.current &&
          queueRef.current.length > 0 &&
          queueRef.current[0].seq === nextSeqRef.current
        ) {
          nextReady = prepareChunk(queueRef.current[0]);
        }

        await finished;
        console.log(`[TTS] drainQueue: seq=${item.seq} finished`);

        // Clean up current
        current.player.remove();
        playersRef.current = playersRef.current.filter((p) => p !== current.player);
        try { current.file.delete(); } catch {}

        prepared = nextReady;
      }
    } catch (e) {
      console.warn("[TTS] playback error:", e);
    } finally {
      if (prepared) {
        prepared.player.remove();
        try { prepared.file.delete(); } catch {}
      }
      drainingRef.current = false;

      // If a new stream arrived while we were playing, switch to it now
      if (pendingResetRef.current) {
        console.log(`[TTS] drainQueue: pending stream swap — ${pendingQueueRef.current.length} pending chunks`);
        pendingResetRef.current = false;
        // Clean up any leftover players
        for (const player of playersRef.current) {
          player.remove();
        }
        playersRef.current = [];
        // Swap pending queue in as the active queue
        queueRef.current = pendingQueueRef.current;
        pendingQueueRef.current = [];
        nextSeqRef.current = 0;
        activeRef.current = !mutedRef.current;
        // 2D: Await the recursive drainQueue call
        if (queueRef.current.length > 0 && activeRef.current) {
          await drainQueue();
        }
      }
    }
  }, []);

  const start = useCallback(() => {
    console.log(`[TTS] start() called (draining=${drainingRef.current}, muted=${mutedRef.current})`);
    if (drainingRef.current) {
      // Audio is currently playing — let it finish, then switch to the new stream
      pendingResetRef.current = true;
      pendingQueueRef.current = [];
      return;
    }
    // Nothing playing — reset immediately
    pendingResetRef.current = false;
    pendingQueueRef.current = [];
    for (const player of playersRef.current) {
      player.remove();
    }
    playersRef.current = [];
    queueRef.current = [];
    nextSeqRef.current = 0;
    drainingRef.current = false;
    activeRef.current = !mutedRef.current;
  }, []);

  const enqueue = useCallback(
    (data: string, sequence: number) => {
      if (mutedRef.current) return;
      // If a pending stream reset is waiting, buffer into the pending queue
      if (pendingResetRef.current) {
        console.log(`[TTS] enqueue(seq=${sequence}) → pending queue`);
        pendingQueueRef.current.push({ seq: sequence, data });
        pendingQueueRef.current.sort((a, b) => a.seq - b.seq);
        return;
      }
      if (!activeRef.current) return;
      console.log(`[TTS] enqueue(seq=${sequence}) → active queue (${queueRef.current.length + 1} items)`);
      queueRef.current.push({ seq: sequence, data });
      queueRef.current.sort((a, b) => a.seq - b.seq);
      drainQueue();
    },
    [drainQueue]
  );

  const done = useCallback(() => {
    console.log(`[TTS] done() called (pending=${pendingResetRef.current})`);
    // If pending, the drain loop will pick it up when it finishes
    if (!pendingResetRef.current) {
      drainQueue();
    }
  }, [drainQueue]);

  const stop = useCallback(() => {
    console.log(`[TTS] stop() called — clearing ${playersRef.current.length} players, ${queueRef.current.length} queued`);
    activeRef.current = false;
    pendingResetRef.current = false;
    pendingQueueRef.current = [];
    for (const player of playersRef.current) {
      player.remove();
    }
    playersRef.current = [];
    queueRef.current = [];
    nextSeqRef.current = 0;
  }, []);

  return { start, enqueue, done, stop, muted, setMuted: updateMuted };
}
