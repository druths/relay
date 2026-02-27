import { useEffect, useState } from "react";
import { StatusBar } from "expo-status-bar";
import { setAudioModeAsync } from "expo-audio";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { getToken, clearToken } from "./src/auth";
import { setOnAuthFailure } from "./src/apiFetch";
import { LoginScreen } from "./src/screens/LoginScreen";
import { RelayScreen } from "./src/screens/RelayScreen";

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null);

  useEffect(() => {
    // Check for existing token
    getToken().then((t) => setAuthed(t !== null));

    // Register callback for 401 responses
    setOnAuthFailure(() => setAuthed(false));
  }, []);

  useEffect(() => {
    // Configure audio session for iOS: play through speaker even in silent mode,
    // and allow recording alongside playback.
    // Start in playback mode (routes to speaker).
    // Recording mode is enabled on-demand by useAudioRecorder, which
    // switches back to playback mode when done.
    setAudioModeAsync({
      playsInSilentMode: true,
      allowsRecording: false,
      shouldPlayInBackground: true,
      interruptionMode: "doNotMix",
    });
  }, []);

  if (authed === null) return null;

  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      {authed ? (
        <RelayScreen
          onLogout={async () => {
            await clearToken();
            setAuthed(false);
          }}
        />
      ) : (
        <LoginScreen onLogin={() => setAuthed(true)} />
      )}
    </SafeAreaProvider>
  );
}
