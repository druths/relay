import SwiftUI
#if canImport(UIKit)
import UIKit
import Runestone

/// Handle the parent holds onto so it can imperatively read the current
/// editor buffer (e.g. on save) without forcing the editor to publish
/// every keystroke through a SwiftUI binding.
@MainActor
final class EditorTextHandle {
    fileprivate weak var view: Runestone.TextView?
    /// Read the live editor buffer. Triggers Runestone's piece-tree walk
    /// to materialize a `String`, so call only when the value is actually
    /// needed (save, not per-keystroke).
    var currentText: String { view?.text ?? "" }
}

/// SwiftUI wrapper around Runestone's `TextView`. The editor owns its
/// own text; the parent supplies an initial value plus a bumpable
/// `cleanVersion` to push a fresh "known-clean" baseline (load / reload
/// / post-save). Dirty state is signalled via callback. No per-keystroke
/// binding round-trip — that was the source of typing lag on large files.
///
/// State surface kept small on purpose: the clean baseline, the wrap
/// flag, focus + dirty callbacks, and three trigger counters (find /
/// resign / clean-version) the parent bumps to invoke imperative actions
/// without owning a ref to the underlying view.
struct SelectableTextEditor: UIViewRepresentable {
    /// Handle through which the parent reads the live buffer on demand.
    let handle: EditorTextHandle
    /// The most recently committed/loaded clean text. Pushed into the
    /// editor when `cleanVersion` changes — i.e. when the parent has
    /// either just loaded the file or just successfully saved it.
    let cleanText: String
    /// Bump whenever `cleanText` represents a new clean baseline that
    /// should be installed into the editor (load) or just-recommitted
    /// from the editor (save). Resets internal dirty tracking.
    let cleanVersion: Int
    /// Drives `isLineWrappingEnabled` on the underlying TextView.
    var wrap: Bool = true
    /// Fires when the editor transitions clean↔dirty due to user edits.
    /// Programmatic resets via `cleanVersion` don't fire this — the
    /// parent already knows it just established a clean state.
    var onDirtyChange: ((Bool) -> Void)? = nil
    /// Fires when the editor becomes / resigns first responder. Used by
    /// `RelayView` to gate single-letter keyboard shortcuts on iPad.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Bump from the parent to ask the editor to resign first responder
    /// (e.g. on Escape).
    var resignTrigger: Int = 0
    /// Bump from the parent to present the system find navigator (⌘F).
    var findTrigger: Int = 0

    func makeUIView(context: Context) -> Runestone.TextView {
        let v = Runestone.TextView()
        v.editorDelegate = context.coordinator
        v.text = cleanText
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
        handle.view = v
        context.coordinator.appliedCleanVersion = cleanVersion
        context.coordinator.lastCleanText = cleanText
        return v
    }

    func updateUIView(_ v: Runestone.TextView, context: Context) {
        let coord = context.coordinator
        // Refresh the coordinator so delegate callbacks see the latest
        // closures + bindings.
        coord.parent = self
        if coord.appliedCleanVersion != cleanVersion {
            coord.appliedCleanVersion = cleanVersion
            // Only push down if the clean baseline really differs from
            // what we last installed. Saves a piece-tree rebuild when the
            // parent re-asserts a clean baseline whose text matches what
            // the editor already holds (e.g. post-save).
            if coord.lastCleanText != cleanText {
                coord.lastCleanText = cleanText
                v.text = cleanText
            }
            // Coordinator's dirty flag is internal; the parent drove this
            // reset, so don't echo it back through `onDirtyChange`.
            coord.dirty = false
        }
        if v.isLineWrappingEnabled != wrap {
            v.isLineWrappingEnabled = wrap
        }
        if coord.lastResignTrigger != resignTrigger {
            coord.lastResignTrigger = resignTrigger
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
        if coord.lastFindTrigger != findTrigger {
            coord.lastFindTrigger = findTrigger
            DispatchQueue.main.async {
                v.findInteraction?.presentFindNavigator(showingReplace: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: TextViewDelegate {
        var parent: SelectableTextEditor
        var appliedCleanVersion: Int = .min
        /// Cached copy of the last clean baseline we installed. Used to
        /// skip the `v.text =` write when the parent re-asserts clean
        /// state with unchanged text.
        var lastCleanText: String = ""
        /// Whether the user has made any edit since the last clean
        /// baseline. Only transitions on edit / programmatic reset.
        var dirty: Bool = false
        var lastResignTrigger: Int = 0
        var lastFindTrigger: Int = 0

        init(_ parent: SelectableTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: Runestone.TextView) {
            // No binding write-back: the editor owns the text. We only
            // surface the clean↔dirty edge transition so the parent can
            // toggle its save button + tab-bar dot.
            if !dirty {
                dirty = true
                parent.onDirtyChange?(true)
            }
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
