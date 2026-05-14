import SwiftUI

struct MessageBubble: View {
    let message: Message

    @Environment(\.relayTheme) private var theme
    @State private var animating = false

    private var isUser: Bool { message.role == .user }
    private var isSystem: Bool { message.role == .system }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .operator: "Operator"
        case .agent: "Agent"
        case .system: ""
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: theme.elevated
        case .operator: theme.operatorBubble
        case .agent: theme.agentBubble
        case .system: .clear
        }
    }

    var body: some View {
        if isSystem {
            HStack(spacing: 8) {
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
                Text(message.textContent)
                    .font(theme.monoFont(size: 12))
                    .foregroundStyle(theme.textQuaternary)
                    .fixedSize()
                Rectangle().fill(theme.border).frame(height: theme.borderWidth)
            }
            .padding(.vertical, 4)
        } else {
            messageBody
        }
    }

    private var messageBody: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 6) {
                    VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                        if !message.textContent.isEmpty {
                            MarkdownText(text: message.textContent)
                        }
                        ForEach(message.attachments) { att in
                            AttachmentPill(attachment: att)
                        }
                    }

                    if message.isStreaming {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                StatusIndicator(color: theme.textTertiary, size: 5)
                                    .scaleEffect(animating ? 1.0 : 0.5)
                                    .opacity(animating ? 1.0 : 0.3)
                                    .animation(
                                        .easeInOut(duration: 0.45)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.15),
                                        value: animating
                                    )
                            }
                        }
                        .padding(.bottom, 3)
                    } else if message.isInterrupted {
                        Image(systemName: "waveform.badge.xmark")
                            .font(.caption)
                            .foregroundStyle(theme.textQuaternary)
                            .padding(.bottom, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .stroke(
                            theme.bubbleBorderColor ?? theme.border.opacity(theme.borderWidth > 1 ? 0.6 : 0),
                            lineWidth: theme.bubbleBorderColor != nil ? theme.borderWidth : (theme.borderWidth > 1 ? theme.borderWidth : 0)
                        )
                )
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .onAppear {
            animating = message.isStreaming
        }
        .onChange(of: message.isStreaming) { _, streaming in
            animating = streaming
        }
    }
}

/// Renders a single file attachment as a tappable pill. On tap, fetches the
/// file with the user's bearer token, writes it to a temp file, and presents
/// a system share sheet so the user can preview/save/share it.
private struct AttachmentPill: View {
    let attachment: FileAttachment

    @Environment(\.relayTheme) private var theme
    @State private var downloading = false
    @State private var shareTarget: ShareTarget?

    private var sizeLabel: String? {
        guard attachment.sizeBytes > 0 else { return nil }
        let b = Double(attachment.sizeBytes)
        if b < 1024 { return "\(Int(b)) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / 1024 / 1024)
    }

    private var fullURL: URL? {
        if attachment.url.hasPrefix("http") { return URL(string: attachment.url) }
        return URL(string: "\(AppConfig.apiBase)\(attachment.url)")
    }

    var body: some View {
        Button { Task { await openAttachment() } } label: {
            HStack(spacing: 6) {
                if downloading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
                Text(attachment.filename)
                    .font(theme.monoFont(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let s = sizeLabel {
                    Text("(\(s))")
                        .font(theme.monoFont(size: 12))
                        .foregroundStyle(theme.textQuaternary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            )
        }
        .buttonStyle(.plain)
        .disabled(downloading)
        .sheet(item: $shareTarget) { target in
            ShareSheet(url: target.url)
        }
    }

    private func openAttachment() async {
        guard let url = fullURL else { return }
        downloading = true
        defer { downloading = false }

        var request = URLRequest(url: url)
        if let token = KeychainService.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[Relay] Attachment download failed: HTTP \(code)")
                return
            }
            // Write to a temp file with the original filename so the share
            // sheet shows a sensible label and the right preview handler.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let fileURL = tmp.appendingPathComponent(attachment.filename)
            try data.write(to: fileURL, options: .atomic)
            await MainActor.run { shareTarget = ShareTarget(url: fileURL) }
        } catch {
            print("[Relay] Attachment download error: \(error)")
        }
    }
}

private struct ShareTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
