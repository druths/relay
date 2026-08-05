import SwiftUI
import MarkdownUI

/// Renders message text as GitHub-flavoured Markdown via `MarkdownUI`.
///
/// Replaces a hand-rolled parser that only supported headers, code, and
/// inline bold/italic/code — losing tables, task lists, blockquote
/// styling, and correct list handling. MarkdownUI gives us all of the
/// above (via cmark-gfm) with theme knobs that adapt to `RelayTheme`.
///
/// The public `MarkdownText(text:)` shape is unchanged so existing call
/// sites don't move.
struct MarkdownText: View {
    let text: String

    @Environment(\.relayTheme) private var theme
    @Environment(\.relayChatFontSize) private var chatFontSize

    var body: some View {
        Markdown(text)
            .markdownTheme(_markdownTheme(theme: theme, chatFontSize: chatFontSize))
            .textSelection(.enabled)
    }
}

// MARK: - Theme mapping

/// Builds a MarkdownUI `Theme` from `RelayTheme`, so palette / font
/// changes flow through consistently (agent bubbles, operator bubbles,
/// TVA vs. default, chat-font-size preference). Kept as a free function
/// rather than an extension so we don't leak MarkdownUI types into the
/// theme module.
///
/// `@MainActor` because the block-style closures capture SwiftUI view
/// modifiers (`markdownMargin`, `markdownTextStyle`, etc.) whose View-
/// receiver context is main-actor-isolated under Swift 6 strict
/// concurrency. The theme object still gets consumed by MarkdownUI at
/// render time — also on MainActor — so this doesn't restrict usage.
@MainActor
private func _markdownTheme(theme: RelayTheme, chatFontSize: CGFloat) -> MarkdownUI.Theme {
    // Font family used for prose. Falls back to system when the theme
    // doesn't specify a custom body font (e.g. Default theme).
    let bodyFontFamily: FontProperties.Family = theme.bodyFontName.map { .custom($0) } ?? .system(.default)
    let monoFontFamily: FontProperties.Family = theme.monoFontName.map { .custom($0) } ?? .system(.monospaced)

    // Colours derived from the RelayTheme palette so light/dark and
    // theme-specific variants stay in sync.
    let primary = theme.textPrimary
    let secondary = theme.textSecondary
    let tertiary = theme.textTertiary
    let border = theme.border
    let elevated = theme.elevated
    let surface = theme.surface

    return MarkdownUI.Theme()
        // ── Inline text ────────────────────────────────────────────
        .text {
            ForegroundColor(secondary)
            FontFamily(bodyFontFamily)
            FontSize(chatFontSize)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .strikethrough {
            StrikethroughStyle(.single)
        }
        .link {
            ForegroundColor(theme.primary)
            UnderlineStyle(.single)
        }
        .code {
            FontFamily(monoFontFamily)
            FontSize(.em(0.92))
            BackgroundColor(elevated)
        }

        // ── Block-level styling ────────────────────────────────────
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: .em(0.25), bottom: .em(0.25))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.6), bottom: .em(0.25))
                .markdownTextStyle {
                    FontSize(chatFontSize + 5)
                    FontWeight(.semibold)
                    ForegroundColor(primary)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.5), bottom: .em(0.2))
                .markdownTextStyle {
                    FontSize(chatFontSize + 3)
                    FontWeight(.semibold)
                    ForegroundColor(primary)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle {
                    FontSize(chatFontSize + 1)
                    FontWeight(.semibold)
                    ForegroundColor(primary)
                }
        }
        .blockquote { configuration in
            configuration.label
                .padding(.vertical, 2)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(border)
                        .frame(width: 2)
                }
                .markdownTextStyle {
                    ForegroundColor(tertiary)
                    FontStyle(.italic)
                }
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontFamily(monoFontFamily)
                        FontSize(chatFontSize - 1)
                        ForegroundColor(secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: max(theme.cornerRadius * 0.6, 4)))
            .markdownMargin(top: .em(0.3), bottom: .em(0.3))
        }
        // ── Lists ──────────────────────────────────────────────────
        // Chat bubbles are narrow; tight bullet indents keep long list
        // items from wrapping too aggressively.
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.1))
        }

        // ── Tables (the reason we're here) ─────────────────────────
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: border))
                .markdownTableBackgroundStyle(
                    .alternatingRows(surface, elevated),
                )
                .markdownMargin(top: .em(0.3), bottom: .em(0.3))
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(chatFontSize - 1)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
}
