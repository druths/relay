import SwiftUI

/// Slim strip below the conversation log that surfaces what the agent
/// is doing mid-turn ("thinking", tool calls, tool results). Single-line
/// summary of the most recent activity; tap to expand into a
/// chronological list with raw JSON for each entry.
struct AgentActivityStrip: View {
    let relay: RelayViewModel

    @Environment(\.relayTheme) private var theme
    @State private var expanded = false

    private var activities: [RelayViewModel.AgentActivity] {
        relay.activities
    }

    var body: some View {
        if !activities.isEmpty {
            VStack(spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        summary(for: activities.last!)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if activities.count > 1 {
                            Text("\(activities.count) steps")
                                .font(theme.monoFont(size: 10))
                                .foregroundStyle(theme.textQuaternary)
                        }
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textQuaternary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(theme.elevated.opacity(0.4))
                .overlay(alignment: .top) {
                    Rectangle().fill(theme.border).frame(height: theme.borderWidth)
                }

                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(activities) { a in
                                detailRow(for: a)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .background(theme.elevated.opacity(0.25))
                    .overlay(alignment: .top) {
                        Rectangle().fill(theme.border.opacity(0.6)).frame(height: theme.borderWidth)
                    }
                }
            }
        }
    }

    // ── Line + detail formatting ─────────────────────────────────────

    @ViewBuilder
    private func summary(for a: RelayViewModel.AgentActivity) -> some View {
        switch a {
        case .thinking(_, let text):
            HStack(spacing: 4) {
                Text("💭")
                Text("Thinking")
                    .foregroundStyle(theme.textSecondary)
                if !text.isEmpty {
                    Text("· \(_truncate(text, 60))")
                        .foregroundStyle(theme.textQuaternary)
                }
            }
            .font(theme.monoFont(size: 11))
        case .toolCall(_, _, let name, let input):
            HStack(spacing: 4) {
                Text("🔧")
                Text(name)
                    .foregroundStyle(theme.textSecondary)
                Text("· \(_summarizeInput(input))")
                    .foregroundStyle(theme.textQuaternary)
            }
            .font(theme.monoFont(size: 11))
        case .toolResult(_, _, let output, let isError):
            HStack(spacing: 4) {
                Text(isError ? "⚠️" : "✓")
                Text(isError ? "result (error)" : "result")
                    .foregroundStyle(isError ? theme.error : theme.textSecondary)
                Text("· \(_summarizeJSON(output, limit: 60))")
                    .foregroundStyle(theme.textQuaternary)
            }
            .font(theme.monoFont(size: 11))
        }
    }

    @ViewBuilder
    private func detailRow(for a: RelayViewModel.AgentActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch a {
            case .thinking(_, let text):
                Text("💭 Thinking")
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textSecondary)
                if !text.isEmpty {
                    Text(text)
                        .font(theme.monoFont(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 14)
                }
            case .toolCall(_, _, let name, let input):
                Text("🔧 \(name)")
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Text(_prettyJson(input))
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 14)
                    .textSelection(.enabled)
            case .toolResult(_, _, let output, let isError):
                Text(isError ? "⚠️ result (error)" : "✓ result")
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(isError ? theme.error : theme.textSecondary)
                Text(_prettyJson(output))
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 14)
                    .textSelection(.enabled)
            }
        }
    }
}

// ── Formatting helpers ────────────────────────────────────────────────

private func _truncate(_ s: String, _ n: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    let trimmed = flat.trimmingCharacters(in: .whitespaces)
    if trimmed.count <= n { return trimmed }
    return String(trimmed.prefix(n)) + "…"
}

private func _summarizeInput(_ v: JSONValue) -> String {
    // Prefer a common "primary field" if present; otherwise fall back
    // to a key-count summary. Keeps the single-line label useful for
    // typical bash/read_file/query-shaped tool calls.
    for k in ["command", "path", "file_path", "query", "url", "prompt"] {
        if case .string(let s) = v.valueForKey(k) ?? .null {
            return _truncate(s, 60)
        }
    }
    if case .object(let dict) = v {
        if dict.isEmpty { return "{}" }
        return "{\(dict.count) field\(dict.count == 1 ? "" : "s")}"
    }
    if case .string(let s) = v { return _truncate(s, 60) }
    return _summarizeJSON(v, limit: 60)
}

private func _summarizeJSON(_ v: JSONValue, limit: Int) -> String {
    if case .string(let s) = v { return _truncate(s, limit) }
    return _truncate(_prettyJson(v), limit)
}

private func _prettyJson(_ v: JSONValue) -> String {
    if case .string(let s) = v { return s }
    do {
        let data = try JSONSerialization.data(
            withJSONObject: v.anyValue,
            options: [.prettyPrinted, .sortedKeys],
        )
        return String(data: data, encoding: .utf8) ?? "\(v)"
    } catch {
        return "\(v)"
    }
}
