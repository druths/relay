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

function prepareChunk(item: QueueItem): PreparedChunk {
  const file = new File(Paths.cache, `relay_tts_${item.seq}.mp3`);
  const binaryStr = atob(item.data);
  const bytes = new Uint8Array(binaryStr.length);
  for (let i = 0; i < binaryStr.length; i++) {
    bytes[i] = binaryStr.charCodeAt(i);
  }
  file.write(bytes);
  const player = createAudioPlayer(file.uri);

  const loaded = new Promise<void>((resolve) => {
    if (player.isLoaded) { resolve(); return; }
    const sub = player.addListener("playbackStatusUpdate", (status: AudioStatus) => {
      if (status.isLoaded) {
        sub.remove();
        resolve();
      }
    });
  });

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

  const updateMuted = useCallback((value: boolean) => {
    mutedRef.current = value;
    setMuted(value);
  }, []);

  const drainQueue = useCallback(async () => {
    if (drainingRef.current) return;
    drainingRef.current = true;

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

        // Set up finish listener before playing to avoid race
        const finished = waitForFinish(current.player);
        current.player.play();

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

        // Clean up current
        current.player.remove();
        playersRef.current = playersRef.current.filter((p) => p !== current.player);
        try { current.file.delete(); } catch {}

        prepared = nextReady;
      }
    } catch (e) {
      console.warn("Audio playback error:", e);
    } finally {
      if (prepared) {
        prepared.player.remove();
        try { prepared.file.delete(); } catch {}
      }
      drainingRef.current = false;
    }
  }, []);

  const start = useCallback(() => {
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
      if (mutedRef.current || !activeRef.current) return;
      queueRef.current.push({ seq: sequence, data });
      queueRef.current.sort((a, b) => a.seq - b.seq);
      drainQueue();
    },
    [drainQueue]
  );

  const done = useCallback(() => {
    drainQueue();
  }, [drainQueue]);

  const stop = useCallback(() => {
    activeRef.current = false;
    for (const player of playersRef.current) {
      player.remove();
    }
    playersRef.current = [];
    queueRef.current = [];
    nextSeqRef.current = 0;
  }, []);

  return { start, enqueue, done, stop, muted, setMuted: updateMuted };
}
