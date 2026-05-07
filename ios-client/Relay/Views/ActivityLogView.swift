import SwiftUI

/// Full-screen scrollable timeline of app lifecycle events. Intended for debugging
/// silent state changes (e.g. unexpected session-leaves while in live mode).
struct ActivityLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.relayTheme) private var theme
    @State private var log = ActivityLog.shared
    @State private var expanded: Set<UUID> = []

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if log.events.isEmpty {
                    VStack(spacing: 8) {
                        Text("No events recorded yet.")
                            .font(theme.bodyFont(size: 16))
                            .foregroundStyle(theme.textTertiary)
                        Text("Events appear here as you use the app.")
                            .font(theme.bodyFont(size: 13))
                            .foregroundStyle(theme.textQuaternary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(log.events.reversed()) { event in
                                    eventRow(event)
                                        .id(event.id)
                                }
                            }
                            .padding(12)
                        }
                        .background(theme.background)
                        .onAppear {
                            if let first = log.events.last { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
            }
            .navigationTitle("Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = log.exportText()
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            log.clear()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(theme.primary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: ActivityEvent) -> some View {
        let isExpanded = expanded.contains(event.id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isExpanded { expanded.remove(event.id) } else { expanded.insert(event.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(timeFormatter.string(from: event.timestamp))
                        .font(theme.monoFont(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 92, alignment: .leading)
                    Text(event.name)
                        .font(theme.bodyFont(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textQuaternary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(event.contextJSON)
                    .font(theme.monoFont(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border.opacity(0.4)).frame(height: theme.borderWidth)
        }
    }
}
