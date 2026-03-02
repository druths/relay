import SwiftUI

struct AgentSelector: View {
    let agents: [Agent]
    let activeAgentName: String?
    let onSelect: (Agent) -> Void

    /// Agents to show — all except the Operator
    private var visibleAgents: [Agent] {
        agents.filter { !$0.isOperator }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer().frame(height: 4)
            Text("AGENTS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color.relayTextQuaternary)
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
                Circle()
                    .fill(statusColor(agent.status))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? Color.relaySuccessLight : Color.relayTextSecondary)

                    Text(agent.llmProvider)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.relayTextQuaternary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.relayAgentActive : Color.relayElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: Agent.AgentStatus) -> Color {
        switch status {
        case .healthy: Color.relaySuccess
        case .error: Color.relayError
        case .unknown: Color.relayTextQuaternary
        }
    }
}
