import SwiftUI

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    // MARK: - Backgrounds
    static let relayBackground = Color(hex: 0x030712)
    static let relaySurface = Color(hex: 0x111827)
    static let relayElevated = Color(hex: 0x1f2937)
    static let relayBorder = Color(hex: 0x374151)

    // MARK: - Text
    static let relayTextPrimary = Color(hex: 0xf9fafb)
    static let relayTextSecondary = Color(hex: 0xe5e7eb)
    static let relayTextTertiary = Color(hex: 0x9ca3af)
    static let relayTextQuaternary = Color(hex: 0x6b7280)
    static let relayTextQuinary = Color(hex: 0x4b5563)

    // MARK: - Semantic
    static let relayPrimary = Color(hex: 0x2563eb)
    static let relayPrimaryLight = Color(hex: 0x3b82f6)
    static let relayPrimaryLighter = Color(hex: 0x93c5fd)
    static let relaySuccess = Color(hex: 0x34d399)
    static let relaySuccessLight = Color(hex: 0x6ee7b7)
    static let relayError = Color(hex: 0xf87171)
    static let relayWarning = Color(hex: 0xca8a04)
    static let relayRecording = Color(hex: 0xdc2626)

    // MARK: - Message bubbles
    static let relayOperatorBubble = Color(.sRGB, red: 30/255, green: 58/255, blue: 138/255, opacity: 0.4)
    static let relayAgentBubble = Color(.sRGB, red: 6/255, green: 78/255, blue: 59/255, opacity: 0.4)
    static let relayAgentActive = Color(.sRGB, red: 6/255, green: 78/255, blue: 59/255, opacity: 0.5)

    // MARK: - Controls
    static let relayMutedButton = Color(.sRGB, red: 127/255, green: 29/255, blue: 29/255, opacity: 0.5)
    static let relayLobbyButton = Color(hex: 0x92400e)
    static let relayNewAgentPill = Color(hex: 0x1e3a5f)
}
