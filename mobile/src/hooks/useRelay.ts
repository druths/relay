import { useCallback, useEffect, useRef, useState } from "react";
import * as Haptics from "expo-haptics";
import { setAudioModeAsync } from "expo-audio";
import type { Agent, Message, Session, WsEvent } from "../types";
import { useAudioPlayer } from "./useAudioPlayer";
import { API_BASE, WS_BASE } from "../config";

export interface RelayState {
  connected: boolean;
  activeSessionId: string | null;
  activeAgentName: string | null;
  activeSpeaker: string;
  status: string;
  lobbyMessages: Message[];
  sessionMessages: Message[];
  agents: Agent[];
  sessions: Session[];
  sttAvailable: boolean;
}

export function useRelay() {
  const ws = useRef<WebSocket | null>(null);
  const audioPlayer = useAudioPlayer();
  const audioPlayerRef = useRef(audioPlayer);
  audioPlayerRef.current = audioPlayer;

  const [state, setState] = useState<RelayState>({
    connected: false,
    activeSessionId: null,
    activeAgentName: null,
    activeSpeaker: "operator",
    status: "idle",
    lobbyMessages: [],
    sessionMessages: [],
    agents: [],
    sessions: [],
    sttAvailable: false,
  });

  // Fetch agent list
  useEffect(() => {
    fetch(`${API_BASE}/v1/agents?include_operator=true`)
      .then((r) => r.json())
      .then((agents: Agent[]) => setState((s) => ({ ...s, agents })))
      .catch(console.error);
  }, []);

  // Fetch sessions list
  const fetchSessions = useCallback(async () => {
    try {
      const res = await fetch(`${API_BASE}/v1/sessions`);
      const sessions: Session[] = await res.json();
      setState((s) => ({ ...s, sessions }));
    } catch {
      // ignore
    }
  }, []);

  // Connect to lobby
  const connect = useCallback(() => {
    const socket = new WebSocket(`${WS_BASE}/v1/lobby`);

    socket.onopen = () => {
      setState((s) => ({ ...s, connected: true }));
      fetchSessions();
      // Check STT availability
      fetch(`${API_BASE}/v1/agents/stt/status`)
        .then((r) => r.json())
        .then((data: { available: boolean }) =>
          setState((s) => ({ ...s, sttAvailable: data.available }))
        )
        .catch(() => {});
    };

    socket.onclose = () => {
      setState((s) => ({ ...s, connected: false, status: "disconnected" }));
    };

    socket.onmessage = (ev) => {
      const event: WsEvent = JSON.parse(ev.data);

      switch (event.type) {
        case "state_update":
          setState((s) => ({
            ...s,
            activeSpeaker: event.payload.active_speaker,
            status: event.payload.status,
          }));
          break;

        case "text":
          setState((s) => {
            if (s.activeSessionId) {
              return {
                ...s,
                sessionMessages: [
                  ...s.sessionMessages,
                  {
                    role: event.payload.speaker === "operator" ? "operator" : "agent",
                    text_content: event.payload.text,
                  },
                ],
              };
            }
            return {
              ...s,
              lobbyMessages: [
                ...s.lobbyMessages,
                { role: "operator", text_content: event.payload.text },
              ],
            };
          });
          break;

        case "handoff":
          if (event.payload.play_earcon) {
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
          }
          break;

        case "session_entered":
          setState((s) => ({
            ...s,
            activeSessionId: event.payload.session_id,
            activeAgentName: event.payload.agent_name,
            sessionMessages: [],
          }));
          fetchSessions();
          break;

        case "session_left":
          audioPlayerRef.current.stop();
          setState((s) => ({
            ...s,
            activeSessionId: null,
            activeAgentName: null,
            sessionMessages: [],
          }));
          fetchSessions();
          break;

        case "session_history":
          setState((s) => ({
            ...s,
            sessionMessages: event.payload.messages,
          }));
          break;

        case "text_start":
          setState((s) => {
            if (s.activeSessionId) {
              return {
                ...s,
                sessionMessages: [
                  ...s.sessionMessages,
                  {
                    role: "agent",
                    text_content: "",
                    streaming: true,
                  },
                ],
              };
            }
            return s;
          });
          break;

        case "text_delta":
          setState((s) => {
            if (!s.activeSessionId) return s;
            const msgs = [...s.sessionMessages];
            const last = msgs[msgs.length - 1];
            if (last && last.streaming) {
              msgs[msgs.length - 1] = {
                ...last,
                text_content: last.text_content + event.payload.delta,
              };
            }
            return { ...s, sessionMessages: msgs };
          });
          break;

        case "text_done":
          setState((s) => {
            if (!s.activeSessionId) return s;
            const msgs = [...s.sessionMessages];
            const last = msgs[msgs.length - 1];
            if (last && last.streaming) {
              msgs[msgs.length - 1] = {
                ...last,
                text_content: event.payload.text,
                streaming: false,
              };
            }
            return { ...s, sessionMessages: msgs };
          });
          break;

        case "session_named":
          setState((s) => ({
            ...s,
            sessions: s.sessions.map((sess) =>
              sess.session_id === event.payload.session_id
                ? { ...sess, name: event.payload.name }
                : sess
            ),
          }));
          break;

        case "audio_start":
          audioPlayerRef.current.start();
          break;

        case "audio_chunk":
          audioPlayerRef.current.enqueue(event.payload.data, event.payload.sequence);
          break;

        case "audio_done":
          audioPlayerRef.current.done();
          break;

        case "transcription":
          console.log(`[STT] transcription received: "${event.payload.text}"`);
          Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
          setState((s) => {
            if (s.activeSessionId) {
              return {
                ...s,
                sessionMessages: [
                  ...s.sessionMessages,
                  { role: "user", text_content: event.payload.text },
                ],
              };
            }
            return {
              ...s,
              lobbyMessages: [
                ...s.lobbyMessages,
                { role: "user", text_content: event.payload.text },
              ],
            };
          });
          break;

        case "error":
          console.error("Relay error:", event.payload.message);
          break;
      }
    };

    ws.current = socket;
  }, [fetchSessions]);

  // Disconnect from lobby
  const disconnect = useCallback(() => {
    audioPlayerRef.current.stop();
    ws.current?.close();
    ws.current = null;
    setState((s) => ({
      ...s,
      connected: false,
      activeSessionId: null,
      activeAgentName: null,
      lobbyMessages: [],
      sessionMessages: [],
      sessions: [],
      status: "idle",
      activeSpeaker: "operator",
    }));
  }, []);

  // Send text message
  const sendMessage = useCallback((text: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;

    setState((s) => {
      if (s.activeSessionId) {
        return {
          ...s,
          sessionMessages: [...s.sessionMessages, { role: "user", text_content: text }],
        };
      }
      return {
        ...s,
        lobbyMessages: [...s.lobbyMessages, { role: "user", text_content: text }],
      };
    });

    ws.current.send(JSON.stringify({ type: "text_input", payload: { text } }));
  }, []);

  // Send audio for STT transcription
  const sendAudio = useCallback((audioBase64: string, format: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) {
      console.warn("[STT] WebSocket not open, cannot send audio");
      return;
    }
    console.log(`[STT] sending audio_input: ${audioBase64.length} base64 chars, format=${format}`);
    ws.current.send(
      JSON.stringify({ type: "audio_input", payload: { data: audioBase64, format } })
    );
  }, []);

  // Leave current agent session, return to lobby
  const leaveSession = useCallback(() => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(JSON.stringify({ type: "leave_session" }));
  }, []);

  // Resume a specific session by ID
  const resumeSession = useCallback((sessionId: string) => {
    if (!ws.current || ws.current.readyState !== WebSocket.OPEN) return;
    ws.current.send(
      JSON.stringify({ type: "resume_session", payload: { session_id: sessionId } })
    );
  }, []);

  // Update agent config
  const updateAgentConfig = useCallback(
    async (agentId: string, config: { voice_settings?: Record<string, number>; voice_id?: string; tts_provider?: string; persona_prompt?: string }) => {
      const res = await fetch(`${API_BASE}/v1/agents/${agentId}/config`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(config),
      });
      const updated: Agent = await res.json();
      setState((s) => ({
        ...s,
        agents: s.agents.map((a) => (a.agent_id === agentId ? updated : a)),
      }));
    },
    []
  );

  const stopAudio = useCallback(() => {
    audioPlayerRef.current.stop();
  }, []);

  const toggleMute = useCallback(() => {
    audioPlayerRef.current.setMuted(!audioPlayerRef.current.muted);
  }, []);

  // Earpiece vs speaker mode
  const [earpieceMode, setEarpieceMode] = useState(false);

  const setOutputMode = useCallback((mode: "speaker" | "earpiece") => {
    const isEarpiece = mode === "earpiece";
    setEarpieceMode(isEarpiece);
    setAudioModeAsync({
      allowsRecording: isEarpiece,
      playsInSilentMode: true,
      interruptionMode: "doNotMix",
    }).catch(() => {});
  }, []);

  return {
    ...state,
    connect,
    disconnect,
    sendMessage,
    sendAudio,
    leaveSession,
    resumeSession,
    updateAgentConfig,
    fetchSessions,
    stopAudio,
    muted: audioPlayer.muted,
    toggleMute,
    earpieceMode,
    setOutputMode,
  };
}
