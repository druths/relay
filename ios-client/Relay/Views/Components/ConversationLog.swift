import SwiftUI

struct ConversationLog: View {
    let messages: [Message]
    let activeSessionId: String?
    let activeAgentName: String?
    let connected: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        if activeSessionId != nil {
                            sessionHeader
                        }

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
                    .font(.system(size: 14))
                    .foregroundStyle(Color.relayTextQuaternary)
            } else if activeSessionId != nil {
                Text("In session with \(activeAgentName ?? "agent"). Loading...")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.relayTextQuaternary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sessionHeader: some View {
        HStack {
            Rectangle()
                .fill(Color.relayBorder)
                .frame(height: 1)
            Text(activeAgentName ?? "Session")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.relayTextTertiary)
            Rectangle()
                .fill(Color.relayBorder)
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}
