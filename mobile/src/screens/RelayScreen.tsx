import { useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { useRelay } from "../hooks/useRelay";
import { StatusOrb } from "../components/StatusOrb";
import { ConversationLog } from "../components/ConversationLog";
import { InputBar } from "../components/InputBar";
import { AgentSelector } from "../components/AgentSelector";
import { SessionList } from "../components/SessionList";
import { AgentManagement } from "../components/AgentManagement";

interface Props {
  onLogout?: () => void;
}

export function RelayScreen({ onLogout }: Props) {
  const relay = useRelay();
  const [showSettings, setShowSettings] = useState(false);

  const handleAgentSelect = (agentName: string) => {
    relay.sendMessage(`connect me to ${agentName}`);
  };

  const inSession = relay.activeSessionId !== null;

  return (
    <SafeAreaView style={styles.safe}>
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === "ios" ? "padding" : undefined}
      >
        {/* Header */}
        <View style={styles.header}>
          <View style={styles.headerLeft}>
            <Text style={styles.title}>Relay</Text>
            <Text style={styles.subtitle}>
              {inSession ? `Session with ${relay.activeAgentName}` : "Lobby"}
            </Text>
          </View>
          <View style={styles.headerRight}>
            {onLogout && (
              <TouchableOpacity onPress={onLogout} hitSlop={12}>
                <Ionicons name="log-out-outline" size={20} color="#6b7280" />
              </TouchableOpacity>
            )}
            <TouchableOpacity
              onPress={() => setShowSettings(true)}
              hitSlop={12}
            >
              <Ionicons name="settings-outline" size={20} color="#6b7280" />
            </TouchableOpacity>
            <StatusOrb
              activeSpeaker={relay.activeSpeaker}
              status={relay.status}
              connected={relay.connected}
            />
          </View>
        </View>

        {/* Session controls */}
        {relay.connected && inSession && (
          <View style={styles.controlRow}>
            <TouchableOpacity
              style={styles.lobbyButton}
              onPress={() => relay.leaveSession()}
            >
              <Text style={styles.controlButtonText}>Back to Lobby</Text>
            </TouchableOpacity>
          </View>
        )}

        {/* Lobby panel: agents + sessions */}
        {relay.connected && !inSession && (
          <ScrollView
            style={styles.lobbyPanel}
            horizontal={false}
            showsVerticalScrollIndicator={false}
          >
            <AgentSelector
              agents={relay.agents}
              activeSpeaker={relay.activeSpeaker}
              onSelect={handleAgentSelect}
              disabled={false}
            />
            <View style={styles.spacer} />
            <SessionList
              sessions={relay.sessions}
              onResume={relay.resumeSession}
            />
          </ScrollView>
        )}

        {/* Conversation */}
        <ConversationLog
          lobbyMessages={relay.lobbyMessages}
          sessionMessages={relay.sessionMessages}
          activeSessionId={relay.activeSessionId}
          activeAgentName={relay.activeAgentName}
        />

        {/* Input */}
        <InputBar
          onSend={relay.sendMessage}
          onSendAudio={relay.sendAudio}
          onStopAudio={relay.stopAudio}
          disabled={!relay.connected}
          muted={relay.muted}
          onToggleMute={relay.toggleMute}
          sttAvailable={relay.sttAvailable}
          outputMode={relay.earpieceMode ? "earpiece" : "speaker"}
          onSetOutputMode={relay.setOutputMode}
          silenceThresholdDb={relay.sttSettings?.stt_silence_threshold_db}
          silenceTimeout={relay.sttSettings?.stt_silence_timeout_ms}
          minDuration={relay.sttSettings?.stt_min_duration_ms}
          sessionId={relay.activeSessionId}
        />
      </KeyboardAvoidingView>

      <AgentManagement
        agents={relay.agents}
        visible={showSettings}
        onClose={() => setShowSettings(false)}
        onAgentsChanged={relay.refreshAgents}
      />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: "#111827",
  },
  flex: {
    flex: 1,
  },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: "#1f2937",
  },
  headerLeft: {
    gap: 2,
  },
  headerRight: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
  },
  title: {
    fontSize: 20,
    fontWeight: "700",
    color: "#f9fafb",
    letterSpacing: -0.3,
  },
  subtitle: {
    fontSize: 12,
    color: "#6b7280",
  },
  controlRow: {
    flexDirection: "row",
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  lobbyButton: {
    flex: 1,
    backgroundColor: "#92400e",
    borderRadius: 10,
    paddingVertical: 10,
    alignItems: "center",
  },
  controlButtonText: {
    color: "#f9fafb",
    fontSize: 14,
    fontWeight: "500",
  },
  lobbyPanel: {
    maxHeight: 200,
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: "#1f2937",
  },
  spacer: {
    height: 12,
  },
});
