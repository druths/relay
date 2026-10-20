import AppIntents
import ActivityKit
import Foundation

extension Notification.Name {
    static let relayToggleMute = Notification.Name("relayToggleMute")
    static let relayExitLive = Notification.Name("relayExitLive")
    static let relayEnterLive = Notification.Name("relayEnterLive")
}

struct ToggleMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Mute"

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .relayToggleMute, object: nil)
        return .result()
    }
}

struct ExitLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Exit Live Mode"

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .relayExitLive, object: nil)
        return .result()
    }
}
