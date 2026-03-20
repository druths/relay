import SwiftUI

struct MessageBubble: View {
    let message: Message

    @State private var animating = false

    private var isUser: Bool { message.role == .user }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .operator: "Operator"
        case .agent: "Agent"
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: Color.relayElevated
        case .operator: Color.relayOperatorBubble
        case .agent: Color.relayAgentBubble
        }
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 6) {
                    MarkdownText(text: message.textContent)

                    if message.isStreaming {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(Color.relayTextTertiary)
                                    .frame(width: 5, height: 5)
                                    .scaleEffect(animating ? 1.0 : 0.5)
                                    .opacity(animating ? 1.0 : 0.3)
                                    .animation(
                                        .easeInOut(duration: 0.45)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.15),
                                        value: animating
                                    )
                            }
                        }
                        .padding(.bottom, 3)
                    } else if message.isInterrupted {
                        Image(systemName: "waveform.badge.xmark")
                            .font(.caption)
                            .foregroundStyle(Color.relayTextQuaternary)
                            .padding(.bottom, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .onAppear {
            animating = message.isStreaming
        }
        .onChange(of: message.isStreaming) { _, streaming in
            animating = streaming
        }
    }
}
