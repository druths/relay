import SwiftUI

struct StatusOrb: View {
    let activeSpeaker: String
    let status: String
    let connected: Bool
    var compact: Bool = false

    @State private var isPulsing = false

    private var orbColor: Color {
        guard connected else { return Color.relayTextQuaternary }
        return activeSpeaker == "operator" ? Color.relayPrimaryLight : Color.relaySuccess
    }

    private var label: String {
        guard connected else { return "OFFLINE" }
        let name = activeSpeaker.uppercased()
        return status == "processing" ? "\(name) THINKING" : name
    }

    private var circleSize: CGFloat { compact ? 32 : 64 }
    private var shadowRadius: CGFloat { compact ? 6 : 12 }
    private var pulseScale: CGFloat { compact ? 1.1 : 1.15 }

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(orbColor)
                .frame(width: circleSize, height: circleSize)
                .shadow(color: orbColor.opacity(0.5), radius: shadowRadius)
                .scaleEffect(shouldPulse ? pulseScale : 1.0)
                .animation(
                    shouldPulse
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: shouldPulse
                )

            if !compact {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(Color.relayTextTertiary)
            }
        }
        .onChange(of: status) { _, newValue in
            isPulsing = newValue == "processing"
        }
        .onAppear {
            isPulsing = status == "processing"
        }
    }

    private var shouldPulse: Bool {
        connected && isPulsing
    }
}
