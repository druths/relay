import { StyleSheet, Text, TouchableOpacity, View } from "react-native";
import type { Session } from "../types";

interface SessionListProps {
  sessions: Session[];
  onResume: (sessionId: string) => void;
}

export function SessionList({ sessions, onResume }: SessionListProps) {
  if (sessions.length === 0) return null;

  return (
    <View style={styles.container}>
      <Text style={styles.heading}>SESSIONS</Text>
      {sessions.map((s) => (
        <TouchableOpacity
          key={s.session_id}
          style={styles.sessionRow}
          onPress={() => onResume(s.session_id)}
        >
          <Text style={styles.sessionName}>
            {s.name || s.agent_name}
          </Text>
          <Text style={styles.sessionDetail}>
            {s.agent_name} · {s.status}
          </Text>
          {s.summary && (
            <Text style={styles.sessionSummary} numberOfLines={2}>
              {s.summary}
            </Text>
          )}
        </TouchableOpacity>
      ))}
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
  sessionRow: {
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 10,
  },
  sessionName: {
    fontSize: 14,
    fontWeight: "500",
    color: "#d1d5db",
  },
  sessionDetail: {
    fontSize: 11,
    color: "#6b7280",
    marginTop: 2,
  },
  sessionSummary: {
    fontSize: 11,
    color: "#4b5563",
    marginTop: 4,
  },
});
