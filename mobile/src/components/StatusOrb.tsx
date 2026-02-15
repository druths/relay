import { useEffect, useRef } from "react";
import { Animated, StyleSheet, Text, View } from "react-native";

interface StatusOrbProps {
  activeSpeaker: string;
  status: string;
  connected: boolean;
}

const SPEAKER_COLORS: Record<string, string> = {
  operator: "#3b82f6", // blue-500
  system: "#9ca3af", // gray-400
};

const AGENT_COLOR = "#10b981"; // emerald-500

export function StatusOrb({ activeSpeaker, status, connected }: StatusOrbProps) {
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const isProcessing = status === "processing";

  useEffect(() => {
    if (isProcessing) {
      const animation = Animated.loop(
        Animated.sequence([
          Animated.timing(pulseAnim, {
            toValue: 1.15,
            duration: 600,
            useNativeDriver: true,
          }),
          Animated.timing(pulseAnim, {
            toValue: 1,
            duration: 600,
            useNativeDriver: true,
          }),
        ])
      );
      animation.start();
      return () => animation.stop();
    }
    pulseAnim.setValue(1);
  }, [isProcessing, pulseAnim]);

  if (!connected) {
    return (
      <View style={styles.container}>
        <View style={[styles.orb, { backgroundColor: "#374151" }]} />
        <Text style={styles.labelOffline}>OFFLINE</Text>
      </View>
    );
  }

  const color = SPEAKER_COLORS[activeSpeaker] || AGENT_COLOR;

  return (
    <View style={styles.container}>
      <Animated.View
        style={[
          styles.orb,
          {
            backgroundColor: color,
            shadowColor: color,
            transform: [{ scale: pulseAnim }],
          },
        ]}
      />
      <Text style={styles.label}>
        {activeSpeaker.toUpperCase()}
        {isProcessing ? " — THINKING" : ""}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: "center",
    gap: 8,
    paddingVertical: 8,
  },
  orb: {
    width: 64,
    height: 64,
    borderRadius: 32,
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.5,
    shadowRadius: 12,
    elevation: 8,
  },
  label: {
    fontSize: 10,
    color: "#9ca3af",
    letterSpacing: 1.5,
    fontWeight: "500",
  },
  labelOffline: {
    fontSize: 10,
    color: "#6b7280",
    letterSpacing: 1.5,
    fontWeight: "500",
  },
});
