import SwiftUI

/// Modal that renders the structured `EndpointReport` returned by
/// `GET /v1/agents/{id}/endpoint-check`. Built for the kind of "ark hung
/// on me again" triage where the user needs to see *which* probe failed
/// (DNS? auth? websocket? Relay's registered connection?) at a glance,
/// and then drill into the raw response when they want the detail.
struct EndpointCheckSheet: View {
    let relay: RelayViewModel
    let agent: Agent

    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme

    @State private var report: EndpointReport?
    @State private var error: String?
    @State private var loading = true
    @State private var expandedCheckIds: Set<String> = []
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    if loading {
                        loadingRow
                    } else if let err = error {
                        errorCard(err)
                    } else if let report {
                        summaryPill(report)
                        checksSection(report)
                        rawSection(report)
                    }
                }
                .padding(16)
            }
            .background(theme.background)
            .navigationTitle("Endpoint Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await runCheck() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
        }
        .task { await runCheck() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agent.name)
                .font(theme.bodyFont(size: 18, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 8) {
                providerChip
                Text(agent.llmModel)
                    .font(theme.monoFont(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let base = report?.baseUrl ?? agent.llmBaseUrl, !base.isEmpty {
                Text(base)
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textQuaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }

    private var providerChip: some View {
        Text(agent.llmProvider)
            .font(theme.monoFont(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.elevated)
            .foregroundStyle(theme.textSecondary)
            .clipShape(Capsule())
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Running checks…")
                .font(theme.bodyFont(size: 13))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private func errorCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Check failed to run")
                .font(theme.bodyFont(size: 14, weight: .semibold))
                .foregroundStyle(theme.error)
            Text(msg)
                .font(theme.monoFont(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.error.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }

    @ViewBuilder
    private func summaryPill(_ report: EndpointReport) -> some View {
        let color = summaryColor(report.summaryStatus)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12)
                Text(summaryLabel(report.summaryStatus))
                    .font(theme.bodyFont(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(report.summaryMessage)
                .font(theme.bodyFont(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }

    @ViewBuilder
    private func checksSection(_ report: EndpointReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHECKS")
                .font(theme.labelFont(size: 11))
                .tracking(1.5)
                .foregroundStyle(theme.textQuaternary)
            VStack(spacing: 1) {
                ForEach(report.checks) { check in
                    checkRow(check)
                }
            }
            .background(theme.border)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }

    @ViewBuilder
    private func checkRow(_ check: EndpointReport.Check) -> some View {
        let expanded = expandedCheckIds.contains(check.id)
        let hasExtra = !check.extra.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon(check.status)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(check.name)
                            .font(theme.bodyFont(size: 14, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if let ms = check.elapsedMs {
                            Text("\(ms)ms")
                                .font(theme.monoFont(size: 11))
                                .foregroundStyle(theme.textQuaternary)
                        }
                    }
                    Text(check.detail)
                        .font(theme.monoFont(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasExtra {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textQuaternary)
                        .padding(.top, 4)
                }
            }
            if expanded && hasExtra {
                Text(prettyJSON(check.extra))
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasExtra else { return }
            if expanded { expandedCheckIds.remove(check.id) }
            else { expandedCheckIds.insert(check.id) }
        }
    }

    @ViewBuilder
    private func rawSection(_ report: EndpointReport) -> some View {
        DisclosureGroup(isExpanded: $showRaw) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prettyJSON(report.raw))
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        } label: {
            Text("Technical details")
                .font(theme.labelFont(size: 12))
                .tracking(1.0)
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - Helpers

    private func statusIcon(_ status: EndpointReport.Check.Status) -> some View {
        let (symbol, color): (String, Color) = {
            switch status {
            case .ok: return ("checkmark.circle.fill", theme.success)
            case .warn: return ("exclamationmark.triangle.fill", theme.warning)
            case .fail: return ("xmark.octagon.fill", theme.error)
            case .skip: return ("minus.circle", theme.textQuaternary)
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(color)
    }

    private func summaryColor(_ status: EndpointReport.SummaryStatus) -> Color {
        switch status {
        case .healthy: theme.success
        case .degraded: theme.warning
        case .down: theme.error
        }
    }

    private func summaryLabel(_ status: EndpointReport.SummaryStatus) -> String {
        switch status {
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        }
    }

    private func prettyJSON(_ value: [String: JSONValue]) -> String {
        let any = value.mapValues(\.anyValue)
        guard let data = try? JSONSerialization.data(
            withJSONObject: any,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        ),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // MARK: - Actions

    private func runCheck() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let report: EndpointReport = try await relay.apiClient.request(
                "GET", path: "/v1/agents/\(agent.agentId)/endpoint-check",
            )
            self.report = report
        } catch {
            self.error = String(describing: error)
        }
    }
}
