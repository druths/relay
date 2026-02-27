import SwiftUI

struct MessageBubble: View {
    let message: Message

    @State private var cursorVisible = true

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
                Text(roleLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.relayTextQuaternary)

                HStack(alignment: .bottom, spacing: 0) {
                    MarkdownText(text: message.textContent)

                    if message.isStreaming {
                        Rectangle()
                            .fill(Color.relaySuccess)
                            .frame(width: 2, height: 14)
                            .opacity(cursorVisible ? 1 : 0)
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
            if message.isStreaming {
                startCursorBlink()
            }
        }
        .onChange(of: message.isStreaming) { _, streaming in
            if streaming {
                startCursorBlink()
            }
        }
    }

    private func startCursorBlink() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            cursorVisible.toggle()
        }
    }
}
