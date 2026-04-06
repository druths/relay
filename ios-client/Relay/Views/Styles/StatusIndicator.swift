import SwiftUI

/// A small status dot that renders as a circle (default theme) or a square (TVA/pixel theme).
struct StatusIndicator: View {
    let color: Color
    var size: CGFloat = 8

    @Environment(\.relayTheme) private var theme

    var body: some View {
        if theme.pixelIndicators {
            Rectangle()
                .fill(color)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }
}

/// An icon that uses SF Symbols in default theme and pixel art / text glyphs in pixel themes.
struct ThemedIcon: View {
    let systemName: String

    @Environment(\.relayTheme) private var theme

    var body: some View {
        if theme.pixelIndicators {
            pixelVersion
        } else {
            Image(systemName: systemName)
        }
    }

    @ViewBuilder
    private var pixelVersion: some View {
        switch systemName {
        case "line.3.horizontal":
            PixelIcons.hamburger(color: theme.textSecondary, size: 3)
        case "waveform":
            PixelIcons.waveform(color: theme.primary, size: 3)
        case "paperplane.fill":
            PixelIcons.returnArrow(color: theme.sendButtonInverted ? theme.background : .white, size: 2.5)
        case "ellipsis":
            PixelIcons.kebab(color: theme.textPrimary, size: 3.5)
        case "xmark.circle.fill":
            PixelIcons.xMark(color: theme.error, size: 3)
        case "mic.fill":
            PixelIcons.mic(color: theme.textSecondary, size: 2.5)
        case "mic.slash.fill":
            PixelIcons.micMuted(color: theme.error, size: 2.5)
        default:
            // Fallback to text glyph for other icons
            Text(Self.textGlyph(for: systemName))
                .font(theme.headingFont(size: 8))
        }
    }

    private static func textGlyph(for name: String) -> String {
        switch name {
        case "gearshape": return "*"
        case "ellipsis": return "..."
        case "chevron.left": return "<"
        case "rectangle.portrait.and.arrow.right": return "->"
        case "pencil": return "ed"
        case "tag": return "#"
        case "trash": return "rm"
        case "checkmark": return "ok"
        case "plus": return "+"
        case "lock.fill": return "[]"
        case "arrow.left": return "<"
        case "arrow.right": return ">"
        case "chevron.down": return "v"
        case "plus.circle.fill": return "[+]"
        case "waveform.badge.xmark": return "~x"
        default: return "?"
        }
    }
}

/// A themed label that uses text glyphs instead of SF Symbols in pixel mode.
struct ThemedLabel: View {
    let title: String
    let systemImage: String

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ThemedIcon(systemName: systemImage)
                .foregroundStyle(theme.textTertiary)
            Text(title)
                .font(theme.bodyFont(size: 16))
        }
    }
}
