import SwiftUI

struct MessageBubble: View {
    let message: Message

    @Environment(\.relayTheme) private var theme
    @State private var animating = false

    private var isUser: Bool { message.role == .user }
    private var isSystem: Bool { message.role == .system }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .operator: "Operator"
        case .agent: "Agent"
        case .system: ""
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: theme.elevated
        case .operator: theme.operatorBubble
        case .agent: theme.agentBubble
        case .system: .clear
        }
    }

    var body: some View {
        if isSystem {
            HStack(spacing: 8) {
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
                Text(message.textContent)
                    .font(theme.monoFont(size: 12))
                    .foregroundStyle(theme.textQuaternary)
                    .fixedSize()
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
            }
            .padding(.vertical, 4)
        } else {
            messageBody
        }
    }

    private var messageBody: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 6) {
                    MarkdownText(text: message.textContent)

                    if message.isStreaming {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                StatusIndicator(color: theme.textTertiary, size: 5)
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
                            .foregroundStyle(theme.textQuaternary)
                            .padding(.bottom, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(
                            theme.bubbleBorderColor ?? theme.border.opacity(theme.borderWidth > 1 ? 0.6 : 0),
                            lineWidth: theme.bubbleBorderColor != nil ? theme.borderWidth : (theme.borderWidth > 1 ? theme.borderWidth : 0)
                        )
                )
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
