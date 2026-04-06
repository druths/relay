import SwiftUI

struct AgentSelector: View {
    let agents: [Agent]
    let activeAgentName: String?
    let onSelect: (Agent) -> Void

    @Environment(\.relayTheme) private var theme

    /// Agents to show — all except the Operator, sorted by sort_order
    private var visibleAgents: [Agent] {
        agents.filter { !$0.isOperator }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer().frame(height: 4)
            Text("AGENTS")
                .font(theme.labelFont(size: 12))
                .tracking(1.5)
                .foregroundStyle(theme.textQuaternary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleAgents) { agent in
                        agentRow(agent)
                    }
                }
                .padding(.horizontal, 16)
            }
            Spacer().frame(height: 4)
        }
    }

    private func agentRow(_ agent: Agent) -> some View {
        let isActive = agent.name == activeAgentName

        return Button(action: { onSelect(agent) }) {
            HStack(spacing: 8) {
                StatusIndicator(color: statusColor(agent.status))

                Text(agent.name)
                    .font(theme.bodyFont(size: 16, weight: .medium))
                    .foregroundStyle(isActive ? theme.successLight : theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? theme.agentActive : theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: Agent.AgentStatus) -> Color {
        switch status {
        case .healthy: theme.success
        case .error: theme.error
        case .unknown: theme.primary
        }
    }
}
