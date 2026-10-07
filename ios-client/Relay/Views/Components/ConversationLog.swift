import SwiftUI

/// Y-position of the bottom sentinel in the ScrollView's coordinate
/// space, reported out via a preference so we can tell whether the
/// user is near the end of the transcript or has scrolled up.
private struct BottomSentinelKey: PreferenceKey {
    // Computed, not stored, so Swift 6 strict concurrency doesn't
    // flag it as nonisolated mutable global state.
    static var defaultValue: CGFloat { .infinity }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ConversationLog: View {
    let messages: [Message]
    let activeSessionId: String?
    let activeAgentName: String?
    let connected: Bool
    var diagnostics: Bool = false
    /// Called when the user taps an attachment that carries a
    /// workspace/project reference and has an openable extension. The
    /// parent resolves the ark scope to an editor invocation.
    /// Attachments without a ref (or with a binary extension) fall
    /// through to the pill's default download-and-preview behavior.
    var onOpenAttachment: ((FileAttachment) -> Void)? = nil

    @Environment(\.relayTheme) private var theme

    /// Measured viewport height of the ScrollView. Updated by a
    /// GeometryReader background below.
    @State private var viewportHeight: CGFloat = 0
    /// Y-position of the bottom sentinel in the ScrollView's
    /// coordinate space. Updated by the sentinel's preference below.
    @State private var sentinelY: CGFloat = .infinity

    /// User is "at the bottom" when the sentinel sits within (or
    /// just below) the visible viewport. 80pt of slack keeps rapid
    /// streaming deltas from flipping the state off and on when the
    /// bubble is growing right at the fold.
    private var isAtBottom: Bool {
        viewportHeight == 0 || sentinelY <= viewportHeight + 80
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { pair in
                            let (idx, message) = pair
                            let prev = idx > 0 ? messages[idx - 1] : nil
                            if message.role == .compaction {
                                CompactionDivider(message: message)
                                    .id(message.id)
                            } else if message.role == .projectChange {
                                ProjectChangeDivider(message: message)
                                    .id(message.id)
                            } else if message.role == .error {
                                ErrorDivider(message: message)
                                    .id(message.id)
                            } else if message.role == .dateMarker {
                                DateMarkerDivider(message: message)
                                    .id(message.id)
                            } else {
                                MessageBubble(
                                    message: message,
                                    diagnostics: diagnostics,
                                    // Header appears only when this
                                    // message's *source agent* differs
                                    // from the previous message's.
                                    // Normal turns from the session's
                                    // own agent leave `metadata.speaker`
                                    // nil, so back-to-back same-agent
                                    // output flows without a divider.
                                    // Cross-agent injected messages
                                    // (whose speaker is set to the
                                    // source agent) get a boundary.
                                    showAgentHeader: _shouldShowAgentHeader(
                                        current: message, previous: prev,
                                    ),
                                    agentName: message.metadata?.speaker
                                        ?? activeAgentName ?? "Agent",
                                    onOpenAttachment: onOpenAttachment,
                                )
                                    .id(message.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)

                // Invisible sentinel at the end of the transcript.
                // Its Y-position in the ScrollView's coordinate space
                // tells us whether the user has scrolled away from
                // the bottom: ≤ viewport height means at-or-near the
                // bottom; much greater means scrolled up. Reported
                // via preference so SwiftUI batches it and we're not
                // mutating @State during view updates.
                Color.clear
                    .frame(height: 1)
                    .background(
                        GeometryReader { sentinelGeo in
                            Color.clear.preference(
                                key: BottomSentinelKey.self,
                                value: sentinelGeo.frame(in: .named("convo")).minY,
                            )
                        }
                        .allowsHitTesting(false)
                    )
                    .allowsHitTesting(false)

                // Breathing room above the input bar. `.scrollTo(id,
                // anchor: .bottom)` positions the LAST message's
                // bottom edge at the viewport bottom — but the
                // thinking-dots strip inside the agent bubble sits at
                // the bubble's bottom, so without a trailing spacer
                // below the message the dots end up flush with the
                // input chrome and get visually clipped. A generous
                // trailing spacer gives the scroll "room to go
                // further" so the whole bubble (dots included) sits
                // comfortably above the fold.
                Color.clear.frame(height: 60).id("__bottom__")
            }
            .coordinateSpace(name: "convo")
            .background(
                // Measure the visible scroll area so we know what
                // "visible" means for the sentinel comparison.
                // `allowsHitTesting(false)` is critical — Color.clear
                // IS hit-testable by default, and a background filling
                // the whole ScrollView would eat the click-drag
                // mouse-downs that Mac Catalyst needs for text
                // selection in Markdown bubbles.
                GeometryReader { outerGeo in
                    Color.clear
                        .onAppear { viewportHeight = outerGeo.size.height }
                        .onChange(of: outerGeo.size.height) { _, h in
                            viewportHeight = h
                        }
                }
                .allowsHitTesting(false)
            )
            .onPreferenceChange(BottomSentinelKey.self) { y in
                sentinelY = y
            }
            .onChange(of: messages.count) { _, _ in
                // New message appended — always follow (user just
                // acted, or agent is beginning a reply). Animated so
                // the transition reads smoothly. Target the trailing
                // spacer rather than the last message so the full
                // bubble (including the thinking-dots strip at its
                // bottom) sits comfortably above the input bar.
                guard messages.last != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
            .onChange(of: messages.last?.textContent.count ?? 0) { _, _ in
                // Streaming delta grew the last bubble. Only follow
                // if the user hasn't scrolled away — reading history
                // mid-stream should NOT yank them back. Non-animated
                // scrollTo so rapid-fire tokens don't produce visible
                // jitter (stacked easing curves look worse than a
                // hard follow).
                guard isAtBottom,
                      let last = messages.last,
                      last.isStreaming else { return }
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
        }
    }

    /// True when the current agent message came from a different
    /// source than the previous message. Speaker is only set on
    /// cross-session-injected messages, so this evaluates to true
    /// exactly in the "different agent just spoke" case — the common
    /// single-agent flow keeps `speaker` nil throughout and renders
    /// as one continuous stream.
    private func _shouldShowAgentHeader(
        current: Message, previous: Message?,
    ) -> Bool {
        guard current.role == .agent,
              let currentSpeaker = current.metadata?.speaker
        else { return false }
        let prevSpeaker = previous?.role == .agent
            ? previous?.metadata?.speaker
            : nil
        return currentSpeaker != prevSpeaker
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack {
            Spacer(minLength: 12)
            if !connected {
                Text("Connect to start...")
                    .font(theme.bodyFont(size: 14))
                    .foregroundStyle(theme.textQuaternary)
            } else if activeSessionId != nil {
                Text("In session with \(activeAgentName ?? "agent"). Loading...")
                    .font(theme.bodyFont(size: 14))
                    .foregroundStyle(theme.textQuaternary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sessionHeader: some View {
        HStack {
            Rectangle()
                .fill(theme.border)
                .frame(height: theme.borderWidth)
            Text(activeAgentName ?? "Session")
                .font(theme.bodyFont(size: 12, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            Rectangle()
                .fill(theme.border)
                .frame(height: theme.borderWidth)
        }
        .padding(.vertical, 4)
    }
}

/// Renders a `role: .error` marker as a full-width divider with an
/// expandable message body. Red so a dead turn reads as visibly
/// distinct from compaction (amber) or project change (blue) at a
/// glance. The chip shows the classified code (context_too_long,
/// rate_limit, auth, token_budget_exceeded, other); tap reveals the
/// raw provider message when there is one.
private struct ErrorDivider: View {
    let message: Message
    @Environment(\.relayTheme) private var theme
    @State private var expanded = false

    private var codeLabel: String {
        switch message.metadata?.code ?? "" {
        case "context_too_long": return "context too long"
        case "rate_limit": return "rate limit"
        case "auth": return "auth"
        case "token_budget_exceeded": return "token budget exceeded"
        case "other": return "provider error"
        case let c where !c.isEmpty: return c
        default: return "error"
        }
    }

    private var bodyMessage: String {
        message.metadata?.message ?? ""
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.error.opacity(0.4))
                    .frame(height: theme.borderWidth)
                Button {
                    if !bodyMessage.isEmpty { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 9))
                        Text("Turn ended — \(codeLabel)")
                            .font(theme.monoFont(size: 11))
                        if !bodyMessage.isEmpty {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(theme.error)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.error.opacity(0.15))
                    .overlay(
                        Capsule().stroke(theme.error.opacity(0.35), lineWidth: theme.borderWidth),
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(bodyMessage.isEmpty)
                Rectangle()
                    .fill(theme.error.opacity(0.4))
                    .frame(height: theme.borderWidth)
            }
            if expanded && !bodyMessage.isEmpty {
                Text(bodyMessage)
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.error.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(theme.error.opacity(0.2), lineWidth: theme.borderWidth),
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Renders a `role: .projectChange` marker as a full-width divider with
/// a chip carrying the server-composed label ("Project changed: A → B",
/// "Project set: X", "Project cleared…"). Tinted blue so it reads as
/// distinct from the amber compaction divider even at a glance.
private struct ProjectChangeDivider: View {
    let message: Message
    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.primary.opacity(0.4))
                .frame(height: theme.borderWidth)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(message.textContent)
                    .font(theme.monoFont(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.primary.opacity(0.12))
            .overlay(
                Capsule().stroke(theme.primary.opacity(0.35), lineWidth: theme.borderWidth),
            )
            .clipShape(Capsule())
            Rectangle()
                .fill(theme.primary.opacity(0.4))
                .frame(height: theme.borderWidth)
        }
        .padding(.vertical, 4)
    }
}

/// Renders a `role: .compaction` marker as a full-width divider with an
/// expandable summary chip. Older messages above stay visible — the user
/// can still scroll back through them.
private struct CompactionDivider: View {
    let message: Message
    @Environment(\.relayTheme) private var theme
    @State private var expanded = false

    private var reasonLabel: String {
        let r = message.metadata?.reason ?? ""
        if r.isEmpty { return "" }
        if r == "client-invoked" { return "manual" }
        if r == "client-supplied" { return "manual (supplied summary)" }
        if r.hasPrefix("auto:") { return "auto (\(String(r.dropFirst("auto:".count))))" }
        if r.hasPrefix("disabled:") { return "skipped: \(String(r.dropFirst("disabled:".count)))" }
        return r
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.warning.opacity(0.4))
                    .frame(height: theme.borderWidth)
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.append")
                            .font(.system(size: 9))
                        let label = reasonLabel
                        Text("Session compacted\(label.isEmpty ? "" : " — \(label)")")
                            .font(theme.monoFont(size: 11))
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.warning.opacity(0.15))
                    .overlay(
                        Capsule().stroke(theme.warning.opacity(0.35), lineWidth: theme.borderWidth),
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Rectangle()
                    .fill(theme.warning.opacity(0.4))
                    .frame(height: theme.borderWidth)
            }
            if expanded && !message.textContent.isEmpty {
                Text(message.textContent)
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.warning.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(theme.warning.opacity(0.2), lineWidth: theme.borderWidth),
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Renders a `role: .dateMarker` row as a subtle inline divider:
/// `── Mon, Oct 5 · 6 days later ──`. Deliberately quieter than the
/// compaction / project-change / error dividers — this is an
/// ambient time cue, not an event the user needs to act on.
private struct DateMarkerDivider: View {
    let message: Message
    @Environment(\.relayTheme) private var theme

    private var label: String {
        let dateStr = _formatDate(message.metadata?.toDate)
        let days = message.metadata?.elapsedDays ?? 0
        let gap: String
        switch days {
        case ...0: gap = ""
        case 1: gap = " · next day"
        default: gap = " · \(days) days later"
        }
        return dateStr + gap
    }

    private func _formatDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let d = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "EEE, MMM d"
        return out.string(from: d)
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.border)
                .frame(height: theme.borderWidth)
            Text(label)
                .font(theme.monoFont(size: 10))
                .foregroundStyle(theme.textQuaternary)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(theme.border)
                .frame(height: theme.borderWidth)
        }
        .padding(.vertical, 6)
    }
}
