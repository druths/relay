import SwiftUI
import UIKit

/// Renders message text with markdown support (headers, fenced code blocks,
/// bold, italic, inline code) using non-editable UITextViews for proper
/// range-based text selection. Each block is rendered as its own view so
/// that no single UITextView handles an excessively long attributed string.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parseBlocks(text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(for: block)
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: MarkdownParser.Block) -> some View {
        switch block {
        case .paragraph(let t):
            SelectableText(source: t, style: .paragraph)
        case .header(let level, let t):
            SelectableText(source: t, style: .header(level))
        case .codeBlock(let code):
            SelectableText(source: code, style: .code)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: MarkdownParser.codeBg))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Block rendering style

private enum BlockStyle: Equatable {
    case paragraph
    case header(Int)
    case code
}

// MARK: - UITextView wrapper

private struct SelectableText: UIViewRepresentable {
    let source: String
    let style: BlockStyle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coord = context.coordinator
        guard source != coord.lastSource || style != coord.lastStyle else { return }
        coord.lastSource = source
        coord.lastStyle = style
        coord.cachedSize = nil
        view.attributedText = MarkdownParser.renderBlock(source, style: style)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let coord = context.coordinator
        if let cached = coord.cachedSize, coord.cachedWidth == width {
            return cached
        }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        coord.cachedWidth = width
        coord.cachedSize = size
        return size
    }

    final class Coordinator {
        var lastSource: String?
        var lastStyle: BlockStyle?
        var cachedSize: CGSize?
        var cachedWidth: CGFloat?
    }
}

// MARK: - Markdown parser

private enum MarkdownParser {
    // Colors matching RelayColors.swift
    static let textSecondary = UIColor(red: 0xe5/255, green: 0xe7/255, blue: 0xeb/255, alpha: 1)
    static let textPrimary = UIColor(red: 0xf9/255, green: 0xfa/255, blue: 0xfb/255, alpha: 1)
    static let codeBg = UIColor(red: 0x11/255, green: 0x18/255, blue: 0x27/255, alpha: 1)
    static let inlineCodeBg = UIColor(red: 0x1f/255, green: 0x29/255, blue: 0x37/255, alpha: 1)

    static let bodyFont = UIFont.systemFont(ofSize: 14)
    static let boldFont = UIFont.boldSystemFont(ofSize: 14)
    static let italicFont = UIFont.italicSystemFont(ofSize: 14)
    static let inlineCodeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let codeBlockFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func headerFont(_ level: Int) -> UIFont {
        let size: CGFloat = level == 1 ? 20 : level == 2 ? 17 : 15
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    // MARK: Block types

    enum Block {
        case paragraph(String)
        case header(level: Int, text: String)
        case codeBlock(code: String)
    }

    // MARK: Render a single block

    static func renderBlock(_ text: String, style: BlockStyle) -> NSAttributedString {
        switch style {
        case .paragraph:
            return renderInlineMarkdown(text, font: bodyFont, color: textSecondary)
        case .header(let level):
            return renderInlineMarkdown(text, font: headerFont(level), color: textPrimary)
        case .code:
            return NSAttributedString(string: text, attributes: [
                .font: codeBlockFont,
                .foregroundColor: textSecondary,
            ])
        }
    }

    // MARK: Block parser

    static func parseBlocks(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        let lines = raw.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let code = codeLines.joined(separator: "\n")
                if !code.isEmpty {
                    blocks.append(.codeBlock(code: code))
                }
                continue
            }

            // Header
            if let header = parseHeader(line) {
                blocks.append(header)
                i += 1
                continue
            }

            // Paragraph — collect lines, splitting on blank lines
            var paraLines: [String] = []
            while i < lines.count
                    && !lines[i].hasPrefix("```")
                    && parseHeader(lines[i]) == nil {
                let currentLine = lines[i]
                if currentLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !paraLines.isEmpty {
                        let para = paraLines.joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !para.isEmpty {
                            blocks.append(.paragraph(para))
                        }
                        paraLines = []
                    }
                } else {
                    paraLines.append(currentLine)
                }
                i += 1
            }
            let para = paraLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !para.isEmpty {
                blocks.append(.paragraph(para))
            }
        }

        return blocks
    }

    static func parseHeader(_ line: String) -> Block? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...3).contains(level),
              line.count > level,
              line[line.index(line.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        return .header(level: level, text: String(line.dropFirst(level + 1)))
    }

    // MARK: Inline markdown

    /// Parses **bold**, *italic*, and `code` within a line of text.
    static func renderInlineMarkdown(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            var earliest: (range: Range<String.Index>, type: InlineType)?

            for delim in InlineType.allCases {
                if let r = remaining.range(of: delim.opening) {
                    if earliest == nil || r.lowerBound < earliest!.range.lowerBound {
                        earliest = (r, delim)
                    }
                }
            }

            guard let match = earliest else {
                result.append(NSAttributedString(string: String(remaining), attributes: baseAttrs))
                break
            }

            if match.range.lowerBound > remaining.startIndex {
                let before = String(remaining[remaining.startIndex..<match.range.lowerBound])
                result.append(NSAttributedString(string: before, attributes: baseAttrs))
            }

            let afterOpening = match.range.upperBound
            if afterOpening < remaining.endIndex,
               let closeRange = remaining[afterOpening...].range(of: match.type.closing) {
                let inner = String(remaining[afterOpening..<closeRange.lowerBound])
                var attrs = baseAttrs
                switch match.type {
                case .bold:
                    attrs[.font] = font.bold
                case .italic:
                    attrs[.font] = font.italic
                case .code:
                    attrs[.font] = inlineCodeFont
                    attrs[.backgroundColor] = inlineCodeBg
                }
                result.append(NSAttributedString(string: inner, attributes: attrs))
                remaining = remaining[closeRange.upperBound...]
            } else {
                result.append(NSAttributedString(string: String(remaining[match.range]), attributes: baseAttrs))
                remaining = remaining[match.range.upperBound...]
            }
        }

        return result
    }

    enum InlineType: CaseIterable {
        case bold, code, italic

        var opening: String {
            switch self {
            case .bold: "**"
            case .code: "`"
            case .italic: "*"
            }
        }
        var closing: String { opening }
    }
}

// MARK: - UIFont helpers

private extension UIFont {
    var bold: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    var italic: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitItalic) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
