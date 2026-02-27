import SwiftUI

struct SessionList: View {
    let sessions: [Session]
    let onResume: (String) -> Void

    var body: some View {
        if sessions.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("PREVIOUS SESSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Color.relayTextQuaternary)
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.relayTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(session.agentName)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.relayTextQuaternary)

                    Text("·")
                        .foregroundStyle(Color.relayTextQuinary)

                    Text(session.status)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.relayTextQuinary)
                }

                if let summary = session.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.relayTextQuinary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 160, alignment: .leading)
            .background(Color.relayElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
