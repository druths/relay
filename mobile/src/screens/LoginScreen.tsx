import { useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { setToken } from "../auth";
import { API_BASE } from "../config";

interface Props {
  onLogin: () => void;
}

export function LoginScreen({ onLogin }: Props) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleLogin = async () => {
    setLoading(true);
    setError("");

    try {
      const res = await fetch(`${API_BASE}/v1/auth/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });

      if (!res.ok) {
        setError("Invalid username or password");
        return;
      }

      const data = await res.json();
      await setToken(data.access_token);
      onLogin();
    } catch {
      setError("Connection failed");
    } finally {
      setLoading(false);
    }
  };

  return (
    <SafeAreaView style={styles.safe}>
      <KeyboardAvoidingView
        style={styles.container}
        behavior={Platform.OS === "ios" ? "padding" : undefined}
      >
        <View style={styles.form}>
          <Text style={styles.title}>Relay</Text>
          <Text style={styles.subtitle}>Sign in to continue</Text>

          <View style={styles.fields}>
            <TextInput
              style={styles.input}
              value={username}
              onChangeText={setUsername}
              placeholder="Username"
              placeholderTextColor="#6b7280"
              autoCapitalize="none"
              autoCorrect={false}
              returnKeyType="next"
            />
            <TextInput
              style={styles.input}
              value={password}
              onChangeText={setPassword}
              placeholder="Password"
              placeholderTextColor="#6b7280"
              secureTextEntry
              returnKeyType="go"
              onSubmitEditing={handleLogin}
            />
          </View>

          {error ? <Text style={styles.error}>{error}</Text> : null}

          <TouchableOpacity
            style={[
              styles.button,
              (loading || !username || !password) && styles.buttonDisabled,
            ]}
            onPress={handleLogin}
            disabled={loading || !username || !password}
          >
            <Text style={styles.buttonText}>
              {loading ? "Signing in\u2026" : "Sign in"}
            </Text>
          </TouchableOpacity>

          <Text style={styles.server}>{API_BASE}</Text>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: "#030712",
  },
  container: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    paddingHorizontal: 24,
  },
  form: {
    width: "100%",
    maxWidth: 360,
    backgroundColor: "#111827",
    borderRadius: 16,
    padding: 32,
    gap: 20,
    alignItems: "center",
  },
  title: {
    fontSize: 24,
    fontWeight: "700",
    color: "#f9fafb",
    letterSpacing: -0.3,
  },
  subtitle: {
    fontSize: 14,
    color: "#6b7280",
    marginTop: -12,
  },
  fields: {
    width: "100%",
    gap: 12,
  },
  input: {
    width: "100%",
    backgroundColor: "#1f2937",
    borderWidth: 1,
    borderColor: "#374151",
    borderRadius: 10,
    paddingHorizontal: 16,
    paddingVertical: 12,
    fontSize: 14,
    color: "#e5e7eb",
  },
  error: {
    fontSize: 13,
    color: "#f87171",
    textAlign: "center",
  },
  button: {
    width: "100%",
    backgroundColor: "#2563eb",
    borderRadius: 10,
    paddingVertical: 12,
    alignItems: "center",
  },
  buttonDisabled: {
    backgroundColor: "#374151",
    opacity: 0.6,
  },
  buttonText: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "600",
  },
  server: {
    fontSize: 11,
    color: "#4b5563",
    marginTop: -8,
  },
});
