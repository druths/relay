import SwiftUI
import AVFoundation

@main
struct RelayApp: App {
    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    switch url.host() {
                    case "toggle-mute":
                        NotificationCenter.default.post(name: .relayToggleMute, object: nil)
                    case "exit-live":
                        NotificationCenter.default.post(name: .relayExitLive, object: nil)
                    default:
                        print("[DeepLink] Unknown URL: \(url)")
                    }
                }
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[Audio] Failed to configure initial audio session: \(error)")
        }
    }
}
