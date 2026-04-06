import SwiftUI

struct SessionList: View {
    let sessions: [Session]
    let onResume: (String) -> Void

    @Environment(\.relayTheme) private var theme

    var body: some View {
        if sessions.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("PREVIOUS SESSIONS")
                    .font(theme.labelFont(size: 12))
                    .tracking(1.5)
                    .foregroundStyle(theme.textQuaternary)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sessions) { session in
                            sessionCard(session)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func sessionCard(_ session: Session) -> some View {
        Button(action: { onResume(session.sessionId) }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name ?? session.agentName)
                    .font(theme.bodyFont(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(session.agentName)
                        .font(theme.monoFont(size: 18))
                        .foregroundStyle(theme.textQuaternary)

                    Text("·")
                        .foregroundStyle(theme.textQuinary)

                    Text(session.status)
                        .font(theme.monoFont(size: 18))
                        .foregroundStyle(theme.textQuinary)
                }

                if !session.labels.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(session.labels.prefix(2), id: \.self) { label in
                            Text(label)
                                .font(theme.monoFont(size: 18, weight: .medium))
                                .foregroundStyle(theme.primary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(theme.primary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if session.labels.count > 2 {
                            Text("+\(session.labels.count - 2)")
                                .font(theme.monoFont(size: 18))
                                .foregroundStyle(theme.textQuaternary)
                        }
                    }
                }

                if let summary = session.summary {
                    Text(summary)
                        .font(theme.bodyFont(size: 20))
                        .foregroundStyle(theme.textQuinary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 160, alignment: .leading)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }
}
