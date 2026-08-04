import SwiftUI

/// Ephemeral "Compacting session…" chip that sits between the
/// conversation log and the input bar while ark is compacting the
/// currently-active session. Reads the compacting state off the
/// view-model and shows / hides itself accordingly. When ark reports
/// token counts, appends a "context was NN% full" note so the user
/// understands why it's happening.
struct CompactingChip: View {
    let relay: RelayViewModel

    @Environment(\.relayTheme) private var theme
    @State private var pulse = false

    private var state: RelayViewModel.CompactingState? {
        guard let sid = relay.activeSessionId else { return nil }
        return relay.compacting[sid]
    }

    private var contextPercent: Int? {
        guard let s = state,
              let inTok = s.inputTokens, inTok > 0,
              let ctx = s.contextWindow, ctx > 0 else { return nil }
        return Int((Double(inTok) / Double(ctx)) * 100)
    }

    var body: some View {
        if state != nil {
            HStack(spacing: 8) {
                // Simple animated dot to signal live activity.
                HStack(spacing: 2) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(theme.warning)
                            .frame(width: 4, height: 4)
                            .opacity(pulse ? 1.0 : 0.3)
                            .animation(
                                .easeInOut(duration: 0.9)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                value: pulse,
                            )
                    }
                }
                Text(
                    contextPercent.map { "Compacting session · context was \($0)% full" }
                    ?? "Compacting session",
                )
                .font(theme.monoFont(size: 11))
                .foregroundStyle(theme.warning)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.warning.opacity(0.12))
            .overlay(alignment: .top) {
                Rectangle().fill(theme.warning.opacity(0.35)).frame(height: theme.borderWidth)
            }
            .onAppear { pulse = true }
        }
    }
}
