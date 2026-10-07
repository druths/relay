import SwiftUI
import AVFoundation

@main
struct RelayApp: App {
    @State private var themeManager = ThemeManager()

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(themeManager: themeManager)
                .environment(\.relayTheme, themeManager.current)
                .environment(\.relayChatFontSize, themeManager.chatFontSize)
                .preferredColorScheme(.dark)
                .overlay { CRTOverlay() }
                #if targetEnvironment(macCatalyst)
                // Mac idiom gives UIKit/SwiftUI buttons a bordered
                // chrome by default, which paints a grey box behind
                // every icon-only button in the app. Setting `.plain`
                // at the root cascades through the view hierarchy;
                // buttons that explicitly set `.borderedProminent`
                // (Sign In, Discard, etc.) still override.
                .buttonStyle(.plain)
                #endif
                .onOpenURL { url in
                    switch url.host() {
                    case "toggle-mute":
                        NotificationCenter.default.post(name: .relayToggleMute, object: nil)
                    case "exit-live":
                        NotificationCenter.default.post(name: .relayExitLive, object: nil)
                    case "live":
                        NotificationCenter.default.post(name: .relayEnterLive, object: nil)
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
