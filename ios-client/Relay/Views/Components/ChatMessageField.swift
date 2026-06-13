import SwiftUI
#if canImport(UIKit)
import UIKit

/// Handle the parent holds onto so it can read the live buffer (on send)
/// without forcing a per-keystroke SwiftUI binding round-trip.
@MainActor
final class ChatMessageFieldHandle {
    fileprivate weak var view: UITextView?
    /// Current buffer contents.
    var currentText: String { view?.text ?? "" }
}

/// Multi-line chat input backed by `UITextView`. Replaces the SwiftUI
/// `TextField(axis: .vertical)` because the latter triggers a SwiftUI
/// re-render + height re-measurement on every keystroke, which can't
/// keep up with hardware-keyboard input rates on iPad.
///
/// UIKit owns the text; SwiftUI only sees the empty↔non-empty edge
/// (drives the send button), focus changes (drives the parent's
/// FocusState mirror), and Cmd+Return submits.
struct ChatMessageField: UIViewRepresentable {
    let handle: ChatMessageFieldHandle
    var placeholder: String = ""
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    var placeholderColor: UIColor = .placeholderText
    /// Lines worth of vertical space at min / max. Below min the field
    /// still shows min lines; above max it scrolls internally.
    var minLines: Int = 1
    var maxLines: Int = 6
    /// Two-way mirror of the underlying first-responder state into the
    /// parent's SwiftUI focus system. Lets the parent programmatically
    /// focus / blur and read whether the input has focus (for global
    /// shortcut gating).
    var focused: FocusState<Bool>.Binding? = nil
    /// Fires only on the trimmed empty↔non-empty edge. Use for send
    /// button enable/disable — won't fire on intermediate keystrokes.
    var onHasContentChange: ((Bool) -> Void)? = nil
    /// Fires when the user presses Cmd+Return — the multi-line send
    /// shortcut. Plain Return inserts a newline.
    var onSubmit: (() -> Void)? = nil
    /// Bump to clear the buffer after a send.
    var clearTrigger: Int = 0

    func makeUIView(context: Context) -> ChatTextView {
        let v = ChatTextView()
        v.delegate = context.coordinator
        v.font = font
        v.textColor = textColor
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.autocorrectionType = .default
        v.autocapitalizationType = .sentences
        v.smartDashesType = .default
        v.smartQuotesType = .default
        v.smartInsertDeleteType = .default
        v.spellCheckingType = .default
        v.isScrollEnabled = false
        v.placeholderLabel.text = placeholder
        v.placeholderLabel.font = font
        v.placeholderLabel.textColor = placeholderColor
        v.minLines = minLines
        v.maxLines = maxLines
        v.onSubmitCommand = { [weak coord = context.coordinator] in
            coord?.parent.onSubmit?()
        }
        handle.view = v
        return v
    }

    func updateUIView(_ v: ChatTextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        if v.font != font { v.font = font }
        if v.textColor != textColor { v.textColor = textColor }
        if v.placeholderLabel.text != placeholder { v.placeholderLabel.text = placeholder }
        if v.placeholderLabel.font != font { v.placeholderLabel.font = font }
        if v.placeholderLabel.textColor != placeholderColor {
            v.placeholderLabel.textColor = placeholderColor
        }
        if v.minLines != minLines { v.minLines = minLines }
        if v.maxLines != maxLines { v.maxLines = maxLines }

        if let focused {
            let want = focused.wrappedValue
            if want && !v.isFirstResponder {
                DispatchQueue.main.async { v.becomeFirstResponder() }
            } else if !want && v.isFirstResponder {
                DispatchQueue.main.async { v.resignFirstResponder() }
            }
        }

        if coord.lastClearTrigger != clearTrigger {
            coord.lastClearTrigger = clearTrigger
            v.text = ""
            v.refreshPlaceholder()
            v.invalidateIntrinsicContentSize()
            if coord.hasContent {
                coord.hasContent = false
                onHasContentChange?(false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatMessageField
        /// Cached edge — re-render the send button only when this flips.
        var hasContent: Bool = false
        var lastClearTrigger: Int = 0

        init(_ parent: ChatMessageField) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            let has = tv.text.contains(where: { !$0.isWhitespace })
            if has != hasContent {
                hasContent = has
                parent.onHasContentChange?(has)
            }
            (tv as? ChatTextView)?.refreshPlaceholder()
            tv.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            if let focused = parent.focused, !focused.wrappedValue {
                focused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            if let focused = parent.focused, focused.wrappedValue {
                focused.wrappedValue = false
            }
        }
    }
}

/// UITextView with an overlay placeholder label, line-bounded intrinsic
/// size, and a Cmd+Return key command for submit. Kept inside the
/// `ChatMessageField` file because nothing else uses it.
final class ChatTextView: UITextView {
    let placeholderLabel = UILabel()
    var minLines: Int = 1
    var maxLines: Int = 6
    /// Closure invoked when the user presses Cmd+Return — wired up by
    /// the SwiftUI wrapper's coordinator to call its `onSubmit`.
    var onSubmitCommand: (() -> Void)?

    init() {
        super.init(frame: .zero, textContainer: nil)
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Place the placeholder where the first line of text would go.
        let inset = textContainerInset
        let padding = textContainer.lineFragmentPadding
        let lineH = ceil((font ?? Self.defaultFont).lineHeight)
        placeholderLabel.frame = CGRect(
            x: inset.left + padding,
            y: inset.top,
            width: bounds.width - inset.left - inset.right - padding * 2,
            height: lineH,
        )
    }

    func refreshPlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    override var intrinsicContentSize: CGSize {
        let f = font ?? Self.defaultFont
        let lineH = ceil(f.lineHeight)
        let insets = textContainerInset.top + textContainerInset.bottom
        let minH = lineH * CGFloat(minLines) + insets
        let maxH = lineH * CGFloat(maxLines) + insets
        let widthForFit = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitted = sizeThatFits(CGSize(width: widthForFit, height: .greatestFiniteMagnitude))
        let needsScroll = fitted.height > maxH
        if isScrollEnabled != needsScroll { isScrollEnabled = needsScroll }
        let h = max(minH, min(maxH, fitted.height))
        return CGSize(width: UIView.noIntrinsicMetric, height: h)
    }

    override var keyCommands: [UIKeyCommand]? {
        var cmds = super.keyCommands ?? []
        let send = UIKeyCommand(
            input: "\r",
            modifierFlags: .command,
            action: #selector(_handleSubmitCommand),
        )
        send.wantsPriorityOverSystemBehavior = true
        cmds.append(send)
        return cmds
    }

    @objc private func _handleSubmitCommand() {
        onSubmitCommand?()
    }

    private static let defaultFont = UIFont.preferredFont(forTextStyle: .body)
}
#endif
