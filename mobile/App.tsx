import { useEffect } from "react";
import { StatusBar } from "expo-status-bar";
import { setAudioModeAsync } from "expo-audio";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { RelayScreen } from "./src/screens/RelayScreen";

export default function App() {
  useEffect(() => {
    // Configure audio session for iOS: play through speaker even in silent mode,
    // and allow recording alongside playback.
    // Start in playback mode (routes to speaker).
    // Recording mode is enabled on-demand by useAudioRecorder, which
    // switches back to playback mode when done.
    setAudioModeAsync({
      playsInSilentMode: true,
      allowsRecording: false,
      shouldPlayInBackground: false,
      interruptionMode: "doNotMix",
    });
  }, []);

  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      <RelayScreen />
    </SafeAreaProvider>
  );
}
