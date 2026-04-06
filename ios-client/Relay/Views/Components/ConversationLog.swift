import SwiftUI

struct ConversationLog: View {
    let messages: [Message]
    let activeSessionId: String?
    let activeAgentName: String?
    let connected: Bool

    @Environment(\.relayTheme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
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
