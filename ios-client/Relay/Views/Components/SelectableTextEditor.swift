import SwiftUI
#if canImport(UIKit)
import UIKit

/// A SwiftUI editable text view backed by `UITextView`, with a
/// vertically-synced line-number gutter on the left. Exposes a binding for
/// the selected range and a `scrollTarget` trigger so callers (in
/// particular the Find bar in `FileEditorView`) can programmatically jump
/// to and highlight a match.
///
/// `TextEditor` is the obvious starting point in SwiftUI, but it doesn't
/// expose selection, scrolling, or anything useful for line numbers —
/// hence the `UIViewRepresentable` wrapper around the UIKit primitive.
struct SelectableTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// Mirrors the caret/selection in the live UITextView. Two-way: setting
    /// this from outside (e.g. on next-match) drives the editor; user edits
    /// push back through it.
    @Binding var selectedRange: NSRange
    /// Bumping this counter triggers a `scrollRangeToVisible` (and an
    /// optional `becomeFirstResponder`). Decoupled from `selectedRange`
    /// because a user's typing-driven selection change shouldn't yank the
    /// scroll position around.
    let scrollTarget: Int
    /// When false, the trigger only scrolls — focus stays where it is.
    /// The Find bar passes false so typing into the find input doesn't
    /// get redirected into the editor on every match advance.
    var shouldFocus: Bool = true
    /// Optional NSRange to highlight (independent from `selectedRange`).
    /// Used by the Find bar to render a visible amber rect over the
    /// current match — UITextView only draws its native selection
    /// highlight when it's first responder, which we avoid during find
    /// so the find input keeps focus.
    var highlightRange: NSRange? = nil
    /// When true, the text container's width tracks the view (soft-wrap
    /// on). When false, the container is given a huge fixed width so
    /// each `\n` is one visual line and the gutter stays honest.
    var wrap: Bool = false
    /// Called whenever the underlying UITextView becomes / resigns first
    /// responder. The parent uses this to gate single-letter keyboard
    /// shortcuts on the iPad — they should be silent while the user is
    /// typing in the editor.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Bump this counter from the parent to ask the editor to resign
    /// first responder (e.g. on Escape). Decoupled from focus state so a
    /// parent push doesn't echo back through `onFocusChange` and create
    /// a feedback loop.
    var resignTrigger: Int = 0

    func makeUIView(context: Context) -> EditorContainer {
        let v = EditorContainer()
        v.editor.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: EditorContainer, context: Context) {
        // Refresh the coordinator's parent reference so its delegate
        // callbacks see the latest closures + bindings (otherwise
        // `onFocusChange` could end up pointing at a stale RelayView).
        context.coordinator.parent = self
        if v.editor.text != text {
            v.editor.text = text
        }
        v.setWrap(wrap)
        v.refreshGutter()

        let safe = _clamp(selectedRange, in: v.editor.text)
        if v.editor.selectedRange != safe {
            v.editor.selectedRange = safe
        }
        // Honor parent-requested resignFirstResponder (Escape from RelayView).
        if context.coordinator.lastResignTrigger != resignTrigger {
            context.coordinator.lastResignTrigger = resignTrigger
            DispatchQueue.main.async { v.editor.resignFirstResponder() }
        }
        if context.coordinator.lastScrollTarget != scrollTarget {
            context.coordinator.lastScrollTarget = scrollTarget
            let shouldFocus = shouldFocus
            DispatchQueue.main.async {
                if shouldFocus { v.editor.becomeFirstResponder() }
                v.editor.scrollRangeToVisible(safe)
                // Layout has to settle before `firstRect(for:)` returns the
                // real frame for the new selection, so position the
                // highlight on the next runloop tick.
                v.applyHighlight(self.highlightRange)
            }
        }
        // Re-apply on every update so changes that don't bump scrollTarget
        // (e.g. typing while find is open) still keep the highlight aligned.
        v.applyHighlight(highlightRange)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextEditor
        var lastScrollTarget: Int = .min
        var lastResignTrigger: Int = 0

        init(_ parent: SelectableTextEditor) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            if parent.text != tv.text { parent.text = tv.text }
            // Hop up to the container so the gutter can re-render line
            // numbers as the user types.
            (tv.superview as? EditorContainer)?.refreshGutter()
        }
        func textViewDidChangeSelection(_ tv: UITextView) {
            if parent.selectedRange != tv.selectedRange {
                parent.selectedRange = tv.selectedRange
            }
        }
        func textViewDidBeginEditing(_ tv: UITextView) {
            parent.onFocusChange?(true)
        }
        func textViewDidEndEditing(_ tv: UITextView) {
            parent.onFocusChange?(false)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tv = scrollView as? UITextView else { return }
            (tv.superview as? EditorContainer)?.syncGutterScroll()
        }
    }

    private func _clamp(_ r: NSRange, in s: String) -> NSRange {
        let nsLen = (s as NSString).length
        let loc = max(0, min(r.location, nsLen))
        let len = max(0, min(r.length, nsLen - loc))
        return NSRange(location: loc, length: len)
    }
}

/// Container view holding the editor and a non-interactive gutter UITextView
/// to its left. Same font + insets so each gutter line aligns visually with
/// its editor line.
final class EditorContainer: UIView {
    let editor: UITextView
    let gutter: UITextView
    private let separator: UIView
    /// Amber-tinted strip sitting behind the text inside the editor's
    /// scroll content. Made visible only while Find has a match.
    private let highlightView: UIView

    private static let monoFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let topInset: CGFloat = 8
    private static let bottomInset: CGFloat = 8

    override init(frame: CGRect) {
        editor = UITextView()
        gutter = UITextView()
        separator = UIView()
        highlightView = UIView()
        super.init(frame: frame)

        backgroundColor = .clear

        // Editor: no wrapping (so each `\n` is one visual line and the
        // gutter stays honest). UITextView wraps by default; defeating it
        // takes two steps: disable text container's width tracking, and
        // give the container a large fixed width.
        editor.backgroundColor = .clear
        editor.font = Self.monoFont
        editor.textColor = .label
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartDashesType = .no
        editor.smartQuotesType = .no
        editor.alwaysBounceVertical = true
        editor.alwaysBounceHorizontal = true
        editor.textContainerInset = UIEdgeInsets(top: Self.topInset, left: 6, bottom: Self.bottomInset, right: 6)
        editor.textContainer.widthTracksTextView = false
        editor.textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude,
        )
        editor.isScrollEnabled = true

        // Gutter: read-only twin styled to match.
        gutter.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.18)
        gutter.font = Self.monoFont
        gutter.textColor = .tertiaryLabel
        gutter.isEditable = false
        gutter.isSelectable = false
        gutter.isScrollEnabled = false
        gutter.textAlignment = .right
        gutter.textContainerInset = UIEdgeInsets(top: Self.topInset, left: 4, bottom: Self.bottomInset, right: 4)
        gutter.textContainer.lineFragmentPadding = 0

        separator.backgroundColor = UIColor.separator.withAlphaComponent(0.4)

        highlightView.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.45)
        highlightView.layer.cornerRadius = 2
        highlightView.isUserInteractionEnabled = false
        highlightView.isHidden = true

        addSubview(gutter)
        addSubview(separator)
        addSubview(editor)
        // Sits inside the editor's scroll content so it moves with the
        // text on scroll. sendSubviewToBack keeps the actual glyphs
        // rendering on top of the tint.
        editor.addSubview(highlightView)
        editor.sendSubviewToBack(highlightView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Cached current wrap mode. Layout / gutter rendering branch on this.
    private var wrapEnabled: Bool = false

    /// Toggle word-wrap on the underlying UITextView. When ON, the text
    /// container's width tracks the view (soft wrap) and the line-number
    /// gutter is hidden — per-row alignment with wrapped continuations
    /// would otherwise drift since each logical line can span multiple
    /// visual rows.
    func setWrap(_ on: Bool) {
        guard on != wrapEnabled else { return }
        wrapEnabled = on
        if on {
            editor.textContainer.widthTracksTextView = true
            editor.textContainer.size = CGSize(
                width: bounds.width,
                height: CGFloat.greatestFiniteMagnitude,
            )
            editor.alwaysBounceHorizontal = false
        } else {
            editor.textContainer.widthTracksTextView = false
            editor.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude,
            )
            editor.alwaysBounceHorizontal = true
        }
        gutter.isHidden = on
        separator.isHidden = on
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if wrapEnabled {
            // Gutter / separator hidden — editor takes the full width.
            gutter.frame = .zero
            separator.frame = .zero
            editor.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        } else {
            let lineCount = max(1, _lineCount(editor.text))
            let digitWidth: CGFloat = "9".size(withAttributes: [.font: Self.monoFont]).width
            let digits = max(2, String(lineCount).count)
            // 8pt padding on each side plus enough room for the widest line number.
            let gutterWidth = (CGFloat(digits) * digitWidth) + 16
            gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
            separator.frame = CGRect(x: gutterWidth, y: 0, width: 1.0 / UIScreen.main.scale, height: bounds.height)
            editor.frame = CGRect(
                x: gutterWidth, y: 0,
                width: bounds.width - gutterWidth,
                height: bounds.height,
            )
        }
    }

    /// Re-render the gutter's "1\n2\n…\nN" payload and re-lay it out so the
    /// gutter widens as the line count grows past a digit threshold.
    /// No-op when wrap is on — the gutter is hidden then.
    func refreshGutter() {
        if wrapEnabled { return }
        let n = max(1, _lineCount(editor.text))
        gutter.text = (1...n).map(String.init).joined(separator: "\n")
        setNeedsLayout()
        layoutIfNeeded()
        syncGutterScroll()
    }

    /// Glue the gutter's contentOffset to the editor's so each number stays
    /// next to its line as the user scrolls.
    func syncGutterScroll() {
        let y = editor.contentOffset.y
        if gutter.contentOffset.y != y {
            gutter.contentOffset = CGPoint(x: 0, y: y)
        }
    }

    /// Position the amber overlay over the given range, or hide it. The
    /// rect comes from `firstRect(for:)`, which works regardless of
    /// first-responder status — exactly what we need while Find owns
    /// focus.
    func applyHighlight(_ range: NSRange?) {
        guard let r = range, r.length > 0 else {
            highlightView.isHidden = true
            return
        }
        let nsLen = (editor.text as NSString).length
        guard r.location + r.length <= nsLen,
              let start = editor.position(from: editor.beginningOfDocument, offset: r.location),
              let end = editor.position(from: start, offset: r.length),
              let textRange = editor.textRange(from: start, to: end)
        else {
            highlightView.isHidden = true
            return
        }
        let rect = editor.firstRect(for: textRange)
        if rect.isNull || rect.isInfinite {
            highlightView.isHidden = true
            return
        }
        // `firstRect` returns coordinates in the text container (= editor's
        // scroll content), which is what we want since `highlightView` is
        // already a subview of the editor.
        highlightView.frame = rect.insetBy(dx: -1, dy: -1)
        highlightView.isHidden = false
    }
}

private func _lineCount(_ s: String) -> Int {
    if s.isEmpty { return 1 }
    var n = 1
    for c in s.unicodeScalars where c == "\n" { n += 1 }
    return n
}
#endif
