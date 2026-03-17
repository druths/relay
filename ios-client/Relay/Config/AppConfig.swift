import Foundation

enum AppConfig {
    private static let defaultBase = "http://localhost:5051"
    private static let serverKey = "relay_server_url"

    /// The user-configured server URL, persisted in UserDefaults.
    static var serverBase: String {
        get {
            UserDefaults.standard.string(forKey: serverKey)
                ?? ProcessInfo.processInfo.environment["RELAY_API_URL"]
                ?? defaultBase
        }
        set {
            UserDefaults.standard.set(newValue, forKey: serverKey)
        }
    }

    /// Base URL for REST API calls.
    static var apiBase: String { serverBase }

    /// Base URL for WebSocket connections (http→ws, https→wss).
    static var wsBase: String {
        serverBase
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
    }
}
