import SwiftUI

// MARK: - Theme Definition

struct RelayTheme: Equatable {
    // Backgrounds
    let background: Color
    let surface: Color
    let elevated: Color
    let border: Color

    // Text
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textQuaternary: Color
    let textQuinary: Color

    // Semantic
    let primary: Color
    let primaryLight: Color
    let primaryLighter: Color
    let success: Color
    let successLight: Color
    let error: Color
    let warning: Color
    let recording: Color

    // Message bubbles
    let operatorBubble: Color
    let agentBubble: Color
    let agentActive: Color

    // Controls
    let mutedButton: Color
    let lobbyButton: Color
    let newAgentPill: Color

    // Typography
    let bodyFontName: String?      // nil = system font
    let headingFontName: String?   // nil = system font
    let monoFontName: String?      // nil = system monospaced

    // Shape
    let cornerRadius: CGFloat
    let borderWidth: CGFloat

    // Effects
    let showScanlines: Bool
    let showCRTVignette: Bool
    let glowColor: Color?

    // Mono-style extras
    let bubbleBorderColor: Color?   // nil = no border on message bubbles
    let sendButtonInverted: Bool    // true = amber bg + black symbol
    let liveButtonInverted: Bool    // true = black bg + amber symbol

    // MARK: - Font Helpers

    func bodyFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = bodyFontName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    func headingFont(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if let name = headingFontName {
            // Press Start 2P renders ~2x wider than system; scale down for fit
            return .custom(name, size: size * 0.55)
        }
        return .system(size: size, weight: weight)
    }

    func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = monoFontName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    /// Whether indicators should be pixel squares vs circles
    var pixelIndicators: Bool { cornerRadius == 0 }

    /// For section labels / uppercase headers
    func labelFont(size: CGFloat) -> Font {
        if let name = headingFontName {
            // Press Start 2P: use the requested size directly (callers should pass appropriate size)
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .semibold)
    }
}

// MARK: - Default Theme (current look)

extension RelayTheme {
    static let defaultTheme = RelayTheme(
        background: Color(hex: 0x030712),
        surface: Color(hex: 0x111827),
        elevated: Color(hex: 0x1f2937),
        border: Color(hex: 0x374151),

        textPrimary: Color(hex: 0xf9fafb),
        textSecondary: Color(hex: 0xe5e7eb),
        textTertiary: Color(hex: 0x9ca3af),
        textQuaternary: Color(hex: 0x6b7280),
        textQuinary: Color(hex: 0x4b5563),

        primary: Color(hex: 0x2563eb),
        primaryLight: Color(hex: 0x3b82f6),
        primaryLighter: Color(hex: 0x93c5fd),
        success: Color(hex: 0x34d399),
        successLight: Color(hex: 0x6ee7b7),
        error: Color(hex: 0xf87171),
        warning: Color(hex: 0xca8a04),
        recording: Color(hex: 0xdc2626),

        operatorBubble: Color(.sRGB, red: 30/255, green: 58/255, blue: 138/255, opacity: 0.4),
        agentBubble: Color(.sRGB, red: 6/255, green: 78/255, blue: 59/255, opacity: 0.4),
        agentActive: Color(.sRGB, red: 6/255, green: 78/255, blue: 59/255, opacity: 0.5),

        mutedButton: Color(.sRGB, red: 127/255, green: 29/255, blue: 29/255, opacity: 0.5),
        lobbyButton: Color(hex: 0x92400e),
        newAgentPill: Color(hex: 0x1e3a5f),

        bodyFontName: nil,
        headingFontName: nil,
        monoFontName: nil,

        cornerRadius: 10,
        borderWidth: 1,

        showScanlines: false,
        showCRTVignette: false,
        glowColor: nil,

        bubbleBorderColor: nil,
        sendButtonInverted: false,
        liveButtonInverted: false
    )
}

// MARK: - Light Theme

extension RelayTheme {
    static let lightTheme = RelayTheme(
        background: Color(hex: 0xffffff),
        surface: Color(hex: 0xf9fafb),
        elevated: Color(hex: 0xf3f4f6),
        border: Color(hex: 0xe5e7eb),

        textPrimary: Color(hex: 0x0f172a),
        textSecondary: Color(hex: 0x334155),
        textTertiary: Color(hex: 0x64748b),
        textQuaternary: Color(hex: 0x94a3b8),
        textQuinary: Color(hex: 0xcbd5e1),

        primary: Color(hex: 0x2563eb),
        primaryLight: Color(hex: 0x3b82f6),
        primaryLighter: Color(hex: 0x60a5fa),
        success: Color(hex: 0x059669),
        successLight: Color(hex: 0x10b981),
        error: Color(hex: 0xdc2626),
        warning: Color(hex: 0xd97706),
        recording: Color(hex: 0xdc2626),

        operatorBubble: Color(.sRGB, red: 37/255, green: 99/255, blue: 235/255, opacity: 0.08),
        agentBubble: Color(.sRGB, red: 5/255, green: 150/255, blue: 105/255, opacity: 0.10),
        agentActive: Color(.sRGB, red: 5/255, green: 150/255, blue: 105/255, opacity: 0.18),

        mutedButton: Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255, opacity: 0.12),
        lobbyButton: Color(hex: 0xfef3c7),
        newAgentPill: Color(hex: 0xdbeafe),

        bodyFontName: nil,
        headingFontName: nil,
        monoFontName: nil,

        cornerRadius: 10,
        borderWidth: 1,

        showScanlines: false,
        showCRTVignette: false,
        glowColor: nil,

        bubbleBorderColor: nil,
        sendButtonInverted: false,
        liveButtonInverted: false
    )
}

// MARK: - TVA Theme

extension RelayTheme {
    static let tvaTheme = RelayTheme(
        background: Color(hex: 0x0a0806),
        surface: Color(hex: 0x141008),
        elevated: Color(hex: 0x1e1810),
        border: Color(hex: 0x3a2e1e),

        textPrimary: Color(hex: 0xe8d4a0),
        textSecondary: Color(hex: 0xc4a870),
        textTertiary: Color(hex: 0x8a7450),
        textQuaternary: Color(hex: 0x5a4a30),
        textQuinary: Color(hex: 0x3a2e1e),

        primary: Color(hex: 0xd49000),
        primaryLight: Color(hex: 0xe8a820),
        primaryLighter: Color(hex: 0xffc040),
        success: Color(hex: 0x40a030),
        successLight: Color(hex: 0x60d040),
        error: Color(hex: 0xc04020),
        warning: Color(hex: 0xd49000),
        recording: Color(hex: 0xc04020),

        operatorBubble: Color(.sRGB, red: 40/255, green: 50/255, blue: 90/255, opacity: 0.2),
        agentBubble: Color(.sRGB, red: 30/255, green: 60/255, blue: 25/255, opacity: 0.25),
        agentActive: Color(.sRGB, red: 64/255, green: 160/255, blue: 48/255, opacity: 0.15),

        mutedButton: Color(.sRGB, red: 160/255, green: 50/255, blue: 30/255, opacity: 0.5),
        lobbyButton: Color(hex: 0x5a4a30),
        newAgentPill: Color(hex: 0x3a2e1e),

        bodyFontName: "VT323-Regular",
        headingFontName: "PressStart2P-Regular",
        monoFontName: "VT323-Regular",

        cornerRadius: 0,
        borderWidth: 2,

        showScanlines: true,
        showCRTVignette: true,
        glowColor: Color(hex: 0xd49000),

        bubbleBorderColor: nil,
        sendButtonInverted: false,
        liveButtonInverted: false
    )
}

// MARK: - TVA Mono Theme

extension RelayTheme {
    private static let amber = Color(hex: 0xd49000)

    static let tvaMonoTheme = RelayTheme(
        background: Color(hex: 0x050400),
        surface: Color(hex: 0x0a0800),
        elevated: Color(hex: 0x100c00),
        border: amber.opacity(0.25),

        textPrimary: amber,
        textSecondary: amber.opacity(0.8),
        textTertiary: amber.opacity(0.5),
        textQuaternary: amber.opacity(0.3),
        textQuinary: amber.opacity(0.15),

        primary: amber,
        primaryLight: Color(hex: 0xe8a820),
        primaryLighter: Color(hex: 0xffc040),
        success: amber,
        successLight: amber.opacity(0.8),
        error: amber,          // Errors distinguished by blink, not color
        warning: amber,
        recording: amber,

        operatorBubble: amber.opacity(0.08),
        agentBubble: amber.opacity(0.12),
        agentActive: amber.opacity(0.10),

        mutedButton: amber.opacity(0.2),
        lobbyButton: amber.opacity(0.15),
        newAgentPill: amber.opacity(0.1),

        bodyFontName: "VT323-Regular",
        headingFontName: "PressStart2P-Regular",
        monoFontName: "VT323-Regular",

        cornerRadius: 0,
        borderWidth: 1,

        showScanlines: true,
        showCRTVignette: true,
        glowColor: amber,

        bubbleBorderColor: amber.opacity(0.3),
        sendButtonInverted: true,
        liveButtonInverted: true
    )
}

// MARK: - Retro Green Theme — phosphor green-on-black monochrome

extension RelayTheme {
    private static let phosphor = Color(hex: 0x33ff33)

    static let retroGreenTheme = RelayTheme(
        background: Color(hex: 0x001000),
        surface: Color(hex: 0x001800),
        elevated: Color(hex: 0x002000),
        border: phosphor.opacity(0.25),

        textPrimary: phosphor,
        textSecondary: phosphor.opacity(0.8),
        textTertiary: phosphor.opacity(0.5),
        textQuaternary: phosphor.opacity(0.3),
        textQuinary: phosphor.opacity(0.15),

        primary: phosphor,
        primaryLight: Color(hex: 0x66ff66),
        primaryLighter: Color(hex: 0x99ff99),
        success: phosphor,
        successLight: phosphor.opacity(0.8),
        error: phosphor,          // Errors distinguished by blink, not color
        warning: phosphor,
        recording: phosphor,

        operatorBubble: phosphor.opacity(0.08),
        agentBubble: phosphor.opacity(0.12),
        agentActive: phosphor.opacity(0.10),

        mutedButton: phosphor.opacity(0.2),
        lobbyButton: phosphor.opacity(0.15),
        newAgentPill: phosphor.opacity(0.1),

        bodyFontName: "VT323-Regular",
        headingFontName: "PressStart2P-Regular",
        monoFontName: "VT323-Regular",

        cornerRadius: 0,
        borderWidth: 1,

        showScanlines: true,
        showCRTVignette: true,
        glowColor: phosphor,

        bubbleBorderColor: phosphor.opacity(0.3),
        sendButtonInverted: true,
        liveButtonInverted: true
    )
}

// MARK: - Theme Name (for persistence)

enum ThemeName: String, CaseIterable {
    case `default` = "default"
    case light = "light"
    case tva = "tva"
    case tvaMono = "tva_mono"
    case retroGreen = "retro_green"

    var displayName: String {
        switch self {
        case .default: "Default"
        case .light: "Light"
        case .tva: "TVA"
        case .tvaMono: "TVA Mono"
        case .retroGreen: "Retro Green"
        }
    }

    var theme: RelayTheme {
        switch self {
        case .default: .defaultTheme
        case .light: .lightTheme
        case .tva: .tvaTheme
        case .tvaMono: .tvaMonoTheme
        case .retroGreen: .retroGreenTheme
        }
    }
}

// MARK: - Environment Key

private struct RelayThemeKey: EnvironmentKey {
    static let defaultValue = RelayTheme.defaultTheme
}

private struct RelayChatFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 16
}

extension EnvironmentValues {
    var relayTheme: RelayTheme {
        get { self[RelayThemeKey.self] }
        set { self[RelayThemeKey.self] = newValue }
    }

    var relayChatFontSize: CGFloat {
        get { self[RelayChatFontSizeKey.self] }
        set { self[RelayChatFontSizeKey.self] = newValue }
    }
}

// MARK: - Theme Manager

@Observable
@MainActor
final class ThemeManager {
    private static let themeKey = "relay_appearance_theme"
    private static let fontSizeKey = "relay_chat_font_size"

    var currentName: ThemeName {
        didSet {
            UserDefaults.standard.set(currentName.rawValue, forKey: Self.themeKey)
        }
    }

    /// Chat text font size (messages + input field). Range: 12–24, default 14 (16 for pixel themes).
    var chatFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(chatFontSize), forKey: Self.fontSizeKey)
        }
    }

    var current: RelayTheme { currentName.theme }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.themeKey) ?? "default"
        self.currentName = ThemeName(rawValue: stored) ?? .default

        let storedSize = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.chatFontSize = storedSize > 0 ? CGFloat(storedSize) : 16
    }
}
