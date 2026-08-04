import SwiftUI

struct ConversationLog: View {
    let messages: [Message]
    let activeSessionId: String?
    let activeAgentName: String?
    let connected: Bool
    var diagnostics: Bool = false

    @Environment(\.relayTheme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { message in
                            if message.role == .compaction {
                                CompactionDivider(message: message)
                                    .id(message.id)
                            } else {
                                MessageBubble(message: message, diagnostics: diagnostics)
                                    .id(message.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
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
