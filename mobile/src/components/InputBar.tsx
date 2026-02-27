import { useCallback, useEffect, useRef, useState } from "react";
import {
  Pressable,
  StyleSheet,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import * as Haptics from "expo-haptics";
import { useAudioRecorder } from "../hooks/useAudioRecorder";
import type { RecordingInput } from "../hooks/useAudioRecorder";
import { DevicePickerModal } from "./DevicePickerModal";
import type { DeviceOption } from "./DevicePickerModal";

interface InputBarProps {
  onSend: (text: string) => void;
  onSendAudio?: (audioBase64: string, format: string) => void;
  onStopAudio?: () => void;
  disabled: boolean;
  muted?: boolean;
  onToggleMute?: () => void;
  sttAvailable?: boolean;
  outputMode?: "speaker" | "earpiece";
  onSetOutputMode?: (mode: "speaker" | "earpiece") => void;
  silenceThresholdDb?: number;
  silenceTimeout?: number;
  minDuration?: number;
  /** Used to detect session changes and restart the recorder */
  sessionId?: string | null;
}

const OUTPUT_OPTIONS: DeviceOption[] = [
  { uid: "speaker", name: "Speaker" },
  { uid: "earpiece", name: "Earpiece" },
];

export function InputBar({
  onSend,
  onSendAudio,
  onStopAudio,
  disabled,
  muted,
  onToggleMute,
  sttAvailable,
  outputMode = "speaker",
  onSetOutputMode,
  silenceThresholdDb,
  silenceTimeout,
  minDuration,
  sessionId,
}: InputBarProps) {
  const [value, setValue] = useState("");
  const prevRecorderState = useRef<string>("idle");

  const {
    recorderState,
    startListening,
    stopListening,
    getAvailableInputs,
    getCurrentInput,
    setInput,
  } = useAudioRecorder({
    onRecordingComplete: (audioBase64, format) => {
      onSendAudio?.(audioBase64, format);
    },
    earpieceMode: outputMode === "earpiece",
    ...(silenceThresholdDb !== undefined && { silenceThresholdDb }),
    ...(silenceTimeout !== undefined && { silenceTimeout }),
    ...(minDuration !== undefined && { minDuration }),
  });

  // Stop agent audio when user starts speaking
  useEffect(() => {
    const prev = prevRecorderState.current;
    prevRecorderState.current = recorderState;

    if (recorderState === "recording" && prev !== "recording") {
      onStopAudio?.();
    }
  }, [recorderState, onStopAudio]);

  // Stop recorder when disconnected
  useEffect(() => {
    if (disabled && recorderState !== "idle") {
      stopListening();
    }
  }, [disabled]); // eslint-disable-line react-hooks/exhaustive-deps

  // Restart recorder when session changes (lobby ↔ agent, or agent → agent)
  // so the audio session is properly re-established.
  // 4A: Properly await stopListening before restarting instead of setTimeout.
  const prevSessionIdRef = useRef(sessionId);
  useEffect(() => {
    if (prevSessionIdRef.current === sessionId) return;
    prevSessionIdRef.current = sessionId;
    if (recorderState === "listening" || recorderState === "recording") {
      let cancelled = false;
      (async () => {
        await stopListening();
        if (!cancelled) {
          await startListening();
        }
      })().catch((e) => console.error("[InputBar] session restart failed:", e));
      return () => { cancelled = true; };
    }
  }, [sessionId]); // eslint-disable-line react-hooks/exhaustive-deps

  const showMic = sttAvailable && onSendAudio;

  // Device picker state
  const [inputPickerVisible, setInputPickerVisible] = useState(false);
  const [outputPickerVisible, setOutputPickerVisible] = useState(false);
  const [availableInputs, setAvailableInputs] = useState<DeviceOption[]>([]);
  const [currentInputUid, setCurrentInputUid] = useState<string | null>(null);
  const [inputsLoading, setInputsLoading] = useState(false);

  const handleSend = () => {
    const trimmed = value.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setValue("");
  };

  const handleMicPress = () => {
    if (recorderState === "idle") {
      startListening();
    } else {
      stopListening();
    }
  };

  const handleMicLongPress = useCallback(async () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    setInputPickerVisible(true);
    setInputsLoading(true);
    try {
      const inputs = await getAvailableInputs();
      setAvailableInputs(inputs.map((i: RecordingInput) => ({ uid: i.uid, name: i.name })));
      const current = await getCurrentInput();
      setCurrentInputUid(current?.uid ?? null);
    } catch {
      setAvailableInputs([]);
    } finally {
      setInputsLoading(false);
    }
  }, [getAvailableInputs, getCurrentInput]);

  const handleSpeakerLongPress = useCallback(() => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    setOutputPickerVisible(true);
  }, []);

  const placeholder =
    recorderState === "listening"
      ? "Listening..."
      : recorderState === "recording"
        ? "Recording..."
        : recorderState === "processing"
          ? "Transcribing..."
          : disabled
            ? "Connect to start..."
            : "Type a message...";

  const micIconColor =
    recorderState === "recording"
      ? "#fff"
      : recorderState === "listening"
        ? "#fff"
        : recorderState === "processing"
          ? "#6b7280"
          : "#9ca3af";

  const micBgStyle =
    recorderState === "recording"
      ? styles.micRecording
      : recorderState === "listening"
        ? styles.micListening
        : recorderState === "processing"
          ? styles.micProcessing
          : styles.micIdle;

  const speakerBgStyle = muted ? styles.mutedButton : styles.controlButton;
  const speakerIconColor = muted ? "#f87171" : "#9ca3af";

  return (
    <View style={styles.container}>
      {/* Top row: controls */}
      <View style={styles.controlRow}>
        {showMic && (
          <Pressable
            style={({ pressed }) => [styles.iconButton, micBgStyle, pressed && styles.pressed]}
            onPress={handleMicPress}
            onLongPress={handleMicLongPress}
            delayLongPress={400}
            disabled={disabled || recorderState === "processing"}
          >
            <Ionicons
              name={recorderState === "processing" ? "ellipsis-horizontal" : "mic"}
              size={20}
              color={micIconColor}
            />
          </Pressable>
        )}
        {onToggleMute && (
          <Pressable
            style={({ pressed }) => [styles.iconButton, speakerBgStyle, pressed && styles.pressed]}
            onPress={onToggleMute}
            onLongPress={handleSpeakerLongPress}
            delayLongPress={400}
          >
            <Ionicons
              name={muted ? "volume-mute" : "volume-high"}
              size={20}
              color={speakerIconColor}
            />
          </Pressable>
        )}
      </View>

      {/* Bottom row: text input + send */}
      <View style={styles.inputRow}>
        <TextInput
          style={[styles.input, (disabled || recorderState !== "idle") && styles.inputDisabled]}
          value={value}
          onChangeText={setValue}
          onSubmitEditing={handleSend}
          editable={!disabled && recorderState === "idle"}
          placeholder={placeholder}
          placeholderTextColor="#6b7280"
          returnKeyType="send"
        />
        <TouchableOpacity
          style={[styles.iconButton, styles.sendButton, (!value.trim() || disabled) && styles.buttonDisabled]}
          onPress={handleSend}
          disabled={disabled || !value.trim() || recorderState !== "idle"}
        >
          <Ionicons name="send" size={18} color="#fff" />
        </TouchableOpacity>
      </View>

      {/* Device picker modals */}
      <DevicePickerModal
        visible={inputPickerVisible}
        title="Input Device"
        options={availableInputs}
        selectedUid={currentInputUid}
        onSelect={(uid) => {
          setInput(uid);
          setCurrentInputUid(uid);
        }}
        onClose={() => setInputPickerVisible(false)}
        loading={inputsLoading}
      />
      <DevicePickerModal
        visible={outputPickerVisible}
        title="Output Device"
        options={OUTPUT_OPTIONS}
        selectedUid={outputMode}
        onSelect={(uid) => onSetOutputMode?.(uid as "speaker" | "earpiece")}
        onClose={() => setOutputPickerVisible(false)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: 8,
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 16,
    borderTopWidth: 1,
    borderTopColor: "#1f2937",
  },
  controlRow: {
    flexDirection: "row",
    gap: 8,
  },
  inputRow: {
    flexDirection: "row",
    gap: 8,
  },
  input: {
    flex: 1,
    backgroundColor: "#1f2937",
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 10,
    fontSize: 14,
    color: "#e5e7eb",
  },
  inputDisabled: {
    opacity: 0.5,
  },
  iconButton: {
    width: 40,
    height: 40,
    borderRadius: 12,
    justifyContent: "center",
    alignItems: "center",
  },
  pressed: {
    opacity: 0.7,
  },
  sendButton: {
    backgroundColor: "#2563eb",
  },
  buttonDisabled: {
    backgroundColor: "#374151",
    opacity: 0.5,
  },
  controlButton: {
    backgroundColor: "#1f2937",
  },
  micIdle: {
    backgroundColor: "#1f2937",
  },
  micListening: {
    backgroundColor: "#ca8a04",
  },
  micRecording: {
    backgroundColor: "#dc2626",
  },
  micProcessing: {
    backgroundColor: "#374151",
  },
  mutedButton: {
    backgroundColor: "rgba(127, 29, 29, 0.5)",
  },
});
