import SwiftUI

/// Slim strip of in-flight and recently-completed uploads. Rendered
/// wherever an upload origin lives — above the input bar for chat
/// uploads, at the top of the file browser for browser uploads. The
/// caller filters `uploads` down to the origin/scope relevant to
/// their surface; this view renders whatever it's handed.
///
/// Successful rows self-fade via a timer on the view-model; failed
/// rows persist until the user hits the `×` dismiss button. In-flight
/// rows show a cancel `×` that aborts the underlying URLSession task.
struct UploadStrip: View {
    let uploads: [UploadItem]
    let onCancel: (UUID) -> Void
    let onDismiss: (UUID) -> Void

    @Environment(\.relayTheme) private var theme

    var body: some View {
        if uploads.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 6) {
                ForEach(uploads) { u in
                    row(for: u)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.surface.opacity(0.9))
            .overlay(alignment: .top) {
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
            }
        }
    }

    @ViewBuilder
    private func row(for u: UploadItem) -> some View {
        let pct: Double = u.sizeBytes > 0
            ? min(1.0, Double(u.uploadedBytes) / Double(u.sizeBytes))
            : (u.status == .done ? 1.0 : 0.0)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(u.filename)
                        .font(theme.monoFont(size: 12))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(_statusLabel(u))
                        .font(theme.monoFont(size: 10))
                        .foregroundStyle(_statusColor(u))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(theme.border.opacity(0.4))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(_barColor(u))
                            .frame(width: geo.size.width * pct, height: 3)
                    }
                }
                .frame(height: 3)
                if u.status == .failed, let err = u.error {
                    Text(err)
                        .font(theme.monoFont(size: 9))
                        .foregroundStyle(theme.error)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Button {
                if u.status == .uploading {
                    onCancel(u.id)
                } else {
                    onDismiss(u.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textQuaternary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
    }

    private func _statusLabel(_ u: UploadItem) -> String {
        switch u.status {
        case .uploading:
            return "\(_formatSize(u.uploadedBytes)) / \(_formatSize(u.sizeBytes))"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func _statusColor(_ u: UploadItem) -> Color {
        switch u.status {
        case .uploading: return theme.textQuaternary
        case .done: return theme.success
        case .failed: return theme.error
        case .cancelled: return theme.textQuaternary
        }
    }

    private func _barColor(_ u: UploadItem) -> Color {
        switch u.status {
        case .uploading: return theme.primary
        case .done: return theme.success
        case .failed: return theme.error
        case .cancelled: return theme.textQuaternary
        }
    }

    private func _formatSize(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / 1024 / 1024)
    }
}
