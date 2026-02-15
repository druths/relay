import { useEffect, useRef } from "react";
import { Animated, StyleSheet, Text, View } from "react-native";
import type { Message } from "../types";

interface MessageBubbleProps {
  message: Message;
}

const ROLE_LABELS: Record<string, string> = {
  user: "You",
  operator: "Operator",
  agent: "Agent",
};

const ROLE_COLORS: Record<string, string> = {
  user: "#1f2937", // gray-800
  operator: "rgba(30, 58, 138, 0.4)", // blue-900/40
  agent: "rgba(6, 78, 59, 0.4)", // emerald-900/40
};

export function MessageBubble({ message }: MessageBubbleProps) {
  const cursorAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (message.streaming) {
      const animation = Animated.loop(
        Animated.sequence([
          Animated.timing(cursorAnim, { toValue: 1, duration: 500, useNativeDriver: true }),
          Animated.timing(cursorAnim, { toValue: 0, duration: 500, useNativeDriver: true }),
        ])
      );
      animation.start();
      return () => animation.stop();
    }
  }, [message.streaming, cursorAnim]);

  const isUser = message.role === "user";
  const bgColor = ROLE_COLORS[message.role] || ROLE_COLORS.agent;
  const label = ROLE_LABELS[message.role] || message.role;

  return (
    <View
      style={[
        styles.bubble,
        { backgroundColor: bgColor },
        isUser ? styles.userBubble : styles.otherBubble,
      ]}
    >
      <Text style={styles.label}>{label}</Text>
      <View style={styles.textRow}>
        <Text style={[styles.text, isUser && styles.userText]}>
          {message.text_content}
        </Text>
        {message.streaming && (
          <Animated.View
            style={[styles.cursor, { opacity: cursorAnim }]}
          />
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  bubble: {
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 12,
    marginBottom: 8,
  },
  userBubble: {
    marginLeft: 48,
    alignSelf: "flex-end",
  },
  otherBubble: {
    marginRight: 48,
    alignSelf: "flex-start",
  },
  label: {
    fontSize: 11,
    color: "#6b7280",
    fontWeight: "600",
    marginBottom: 4,
  },
  textRow: {
    flexDirection: "row",
    alignItems: "flex-end",
  },
  text: {
    fontSize: 14,
    color: "#e5e7eb",
    lineHeight: 20,
    flexShrink: 1,
  },
  userText: {
    textAlign: "right",
  },
  cursor: {
    width: 8,
    height: 16,
    backgroundColor: "#34d399",
    borderRadius: 2,
    marginLeft: 2,
  },
});
