import SwiftUI
#if canImport(UIKit)
import UIKit
import Runestone

/// SwiftUI wrapper around Runestone's `TextView`. Runestone gives us a
/// real code editor (gutter + line numbers that survive wrap toggling,
/// soft-wrap, and the iOS 16+ system find navigator) — replacing the
/// hand-rolled `UITextView` + gutter we used to ship.
///
/// State surface kept small on purpose: text in/out, the wrap flag, focus
/// callbacks for the keyboard-shortcut gate in `RelayView`, and two
/// trigger counters (find / resign) the parent bumps to invoke imperative
/// actions without owning a ref to the underlying view.
struct SelectableTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// Drives `isLineWrappingEnabled` on the underlying TextView.
    var wrap: Bool = true
    /// Called whenever the editor becomes / resigns first responder. The
    /// parent uses this to gate single-letter keyboard shortcuts on iPad
    /// — they should be silent while the user is typing in the editor.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Bump from the parent to ask the editor to resign first responder
    /// (e.g. on Escape). Decoupled from focus state so a parent push
    /// doesn't echo back through `onFocusChange` and create a loop.
    var resignTrigger: Int = 0
    /// Bump from the parent to present the system find navigator (⌘F).
    /// Uses Runestone's built-in `UIFindInteraction`, which handles
    /// highlighting, next/prev, and replace on its own.
    var findTrigger: Int = 0

    func makeUIView(context: Context) -> Runestone.TextView {
        let v = Runestone.TextView()
        v.editorDelegate = context.coordinator
        v.text = text
        v.theme = DefaultTheme()
        v.showLineNumbers = true
        v.isLineWrappingEnabled = wrap
        v.isFindInteractionEnabled = true
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartDashesType = .no
        v.smartQuotesType = .no
        v.spellCheckingType = .no
        v.keyboardType = .asciiCapable
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: Runestone.TextView, context: Context) {
        // Refresh the coordinator so delegate callbacks see the latest
        // closures + bindings (otherwise `onFocusChange` could end up
        // pointing at a stale parent).
        context.coordinator.parent = self
        if v.text != text { v.text = text }
        if v.isLineWrappingEnabled != wrap {
            v.isLineWrappingEnabled = wrap
        }
        if context.coordinator.lastResignTrigger != resignTrigger {
            context.coordinator.lastResignTrigger = resignTrigger
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
        if context.coordinator.lastFindTrigger != findTrigger {
            context.coordinator.lastFindTrigger = findTrigger
            DispatchQueue.main.async {
                v.findInteraction?.presentFindNavigator(showingReplace: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: TextViewDelegate {
        var parent: SelectableTextEditor
        var lastResignTrigger: Int = 0
        var lastFindTrigger: Int = 0

        init(_ parent: SelectableTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: Runestone.TextView) {
            if parent.text != textView.text { parent.text = textView.text }
        }
        func textViewDidBeginEditing(_ textView: Runestone.TextView) {
            parent.onFocusChange?(true)
        }
        func textViewDidEndEditing(_ textView: Runestone.TextView) {
            parent.onFocusChange?(false)
        }
    }
}
#endif
