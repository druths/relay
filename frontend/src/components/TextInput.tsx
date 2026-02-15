import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { useAudioRecorder } from "../hooks/useAudioRecorder";

interface TextInputProps {
  onSend: (text: string) => void;
  onSendAudio?: (audioBase64: string, format: string) => void;
  onStopAudio?: () => void;
  disabled: boolean;
  muted?: boolean;
  onToggleMute?: () => void;
  sttAvailable?: boolean;
}

export function TextInput({
  onSend,
  onSendAudio,
  onStopAudio,
  disabled,
  muted,
  onToggleMute,
  sttAvailable,
}: TextInputProps) {
  const [value, setValue] = useState("");
  const prevRecorderState = useRef<string>("idle");

  const { recorderState, startListening, stopListening } = useAudioRecorder({
    onRecordingComplete: (audioBase64, format) => {
      onSendAudio?.(audioBase64, format);
    },
  });

  // Stop agent audio when user starts speaking
  useEffect(() => {
    const prev = prevRecorderState.current;
    prevRecorderState.current = recorderState;

    if (recorderState === "recording" && prev !== "recording") {
      onStopAudio?.();
    }
  }, [recorderState, onStopAudio]);

  const showMic = sttAvailable && onSendAudio;

  const handleSend = () => {
    const trimmed = value.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setValue("");
  };

  const handleKey = (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  const handleMicClick = () => {
    if (recorderState === "idle") {
      startListening();
    } else {
      stopListening();
    }
  };

  const placeholder =
    recorderState === "listening"
      ? "Listening…"
      : recorderState === "recording"
        ? "Recording…"
        : recorderState === "processing"
          ? "Transcribing…"
          : disabled
            ? "Connect to start…"
            : "Type a message…";

  return (
    <div className="flex gap-2 p-4 border-t border-gray-800">
      <input
        type="text"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={handleKey}
        disabled={disabled || recorderState !== "idle"}
        placeholder={placeholder}
        className="flex-1 bg-gray-800 rounded-lg px-4 py-2 text-sm outline-none
                   focus:ring-2 focus:ring-blue-500 disabled:opacity-50
                   placeholder-gray-500"
      />
      <button
        onClick={handleSend}
        disabled={disabled || !value.trim() || recorderState !== "idle"}
        className="bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700
                   disabled:opacity-50 rounded-lg px-5 py-2 text-sm font-medium
                   transition-colors"
      >
        Send
      </button>
      {showMic && (
        <button
          onClick={handleMicClick}
          disabled={disabled || recorderState === "processing"}
          className={`rounded-lg px-3 py-2 text-sm transition-colors ${
            recorderState === "recording"
              ? "bg-red-600 text-white hover:bg-red-500 animate-pulse"
              : recorderState === "listening"
                ? "bg-yellow-600 text-white hover:bg-yellow-500"
                : recorderState === "processing"
                  ? "bg-gray-700 text-gray-400"
                  : "bg-gray-800 text-gray-400 hover:bg-gray-700"
          }`}
          title={
            recorderState === "recording"
              ? "Stop recording"
              : recorderState === "listening"
                ? "Listening for speech…"
                : recorderState === "processing"
                  ? "Transcribing…"
                  : "Start voice input"
          }
        >
          {recorderState === "processing" ? "…" : "Mic"}
        </button>
      )}
      {onToggleMute && (
        <button
          onClick={onToggleMute}
          className={`rounded-lg px-3 py-2 text-sm transition-colors ${
            muted
              ? "bg-red-900/50 text-red-400 hover:bg-red-900/70"
              : "bg-gray-800 text-gray-400 hover:bg-gray-700"
          }`}
          title={muted ? "Unmute audio" : "Mute audio"}
        >
          {muted ? "Muted" : "Audio"}
        </button>
      )}
    </div>
  );
}

