import { StyleSheet, Text, TouchableOpacity, View } from "react-native";
import type { Agent } from "../types";

interface AgentSelectorProps {
  agents: Agent[];
  activeSpeaker: string;
  onSelect: (agentName: string) => void;
  disabled: boolean;
}

export function AgentSelector({
  agents,
  activeSpeaker,
  onSelect,
  disabled,
}: AgentSelectorProps) {
  const connectable = agents.filter((a) => a.name !== "Operator");

  return (
    <View style={styles.container}>
      <Text style={styles.heading}>AGENTS</Text>
      {connectable.map((agent) => {
        const isActive =
          activeSpeaker.toLowerCase() === agent.name.toLowerCase();
        const statusColor =
          agent.status === "healthy"
            ? "#34d399"
            : agent.status === "error"
              ? "#f87171"
              : "#6b7280";

        return (
          <TouchableOpacity
            key={agent.agent_id}
            style={[
              styles.agentRow,
              isActive && styles.agentRowActive,
              disabled && styles.agentRowDisabled,
            ]}
            onPress={() => onSelect(agent.name)}
            disabled={disabled}
          >
            <View style={styles.nameRow}>
              <View style={[styles.dot, { backgroundColor: statusColor }]} />
              <Text
                style={[
                  styles.agentName,
                  isActive && styles.agentNameActive,
                ]}
              >
                {agent.name}
              </Text>
            </View>
            <Text style={styles.agentDetail} numberOfLines={1}>
              {agent.status === "error"
                ? agent.status_message
                : agent.llm_provider ?? agent.tts_provider}
            </Text>
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: 4,
  },
  heading: {
    fontSize: 10,
    fontWeight: "700",
    color: "#6b7280",
    letterSpacing: 1.5,
    paddingHorizontal: 4,
    marginBottom: 4,
  },
  agentRow: {
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 10,
  },
  agentRowActive: {
    backgroundColor: "rgba(6, 78, 59, 0.5)",
  },
  agentRowDisabled: {
    opacity: 0.5,
  },
  nameRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  agentName: {
    fontSize: 14,
    fontWeight: "500",
    color: "#d1d5db",
  },
  agentNameActive: {
    color: "#6ee7b7",
  },
  agentDetail: {
    fontSize: 11,
    color: "#6b7280",
    marginLeft: 16,
    marginTop: 2,
  },
});
