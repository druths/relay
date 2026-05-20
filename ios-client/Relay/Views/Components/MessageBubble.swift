import SwiftUI
import QuickLook

struct MessageBubble: View {
    let message: Message
    var diagnostics: Bool = false

    @Environment(\.relayTheme) private var theme
    @State private var animating = false

    private var isUser: Bool { message.role == .user }
    private var isSystem: Bool { message.role == .system }

    private static let _diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let _diagDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        return f
    }()

    private var formattedTimestamp: String? {
        guard let ts = message.createdAt else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(ts) {
            return Self._diagTimeFormatter.string(from: ts)
        }
        return Self._diagDateTimeFormatter.string(from: ts)
    }

    private var diagnosticsLine: String? {
        guard diagnostics else { return nil }
        var parts: [String] = []
        if let ts = formattedTimestamp { parts.append(ts) }
        if message.role == .agent, let u = message.metadata?.usage {
            let inTok = u.inputTokens ?? 0
            let outTok = u.outputTokens ?? 0
            if inTok > 0 || outTok > 0 {
                var usagePart = "\(inTok) in / \(outTok) out"
                if let ctx = u.contextWindow, ctx > 0 {
                    let used = inTok + outTok
                    let pct = (Double(used) / Double(ctx)) * 100.0
                    let pctStr = pct >= 10 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
                    usagePart += " · \(used.formatted()) / \(ctx.formatted()) (\(pctStr))"
                }
                if let model = u.model, !model.isEmpty {
                    usagePart += " · \(model)"
                }
                parts.append(usagePart)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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

                if let line = diagnosticsLine {
                    Text(line)
                        .font(theme.monoFont(size: 10))
                        .foregroundStyle(theme.textQuaternary)
                        .lineLimit(2)
                        .multilineTextAlignment(isUser ? .trailing : .leading)
                }
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

/// Renders a single file attachment as a pill with two distinct gestures:
///
/// • **Tap** — downloads the file and shows a QuickLook preview (whose own
///   toolbar provides Share / Save to Files / etc.).
/// • **Long press** — surfaces a SwiftUI context menu with Share + Copy Link
///   for quick export without opening the preview.
private struct AttachmentPill: View {
    let attachment: FileAttachment

    @Environment(\.relayTheme) private var theme
    @State private var downloading = false
    @State private var previewURL: FileURLRef?
    @State private var shareURL: FileURLRef?

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
        Button {
            Task { await openPreview() }
        } label: {
            pillContent
        }
        .buttonStyle(.plain)
        .disabled(downloading)
        .contextMenu {
            Button {
                Task { await openShare() }
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = fullURL?.absoluteString ?? attachment.url
                #endif
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        }
        .sheet(item: $previewURL) { wrapped in
            QuickLookPreview(url: wrapped.url)
                .ignoresSafeArea()
        }
        .sheet(item: $shareURL) { wrapped in
            ShareSheet(url: wrapped.url)
        }
    }

    private var pillContent: some View {
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

    private func openPreview() async {
        if let url = await downloadToTemp() {
            await MainActor.run { previewURL = FileURLRef(url: url) }
        }
    }

    private func openShare() async {
        if let url = await downloadToTemp() {
            await MainActor.run { shareURL = FileURLRef(url: url) }
        }
    }

    /// Download the attachment with auth, write it to a temp file with the
    /// original filename, return the local URL. QuickLook and ShareSheet
    /// both consume a file URL; using the real filename keeps the title and
    /// extension-based handlers correct.
    private func downloadToTemp() async -> URL? {
        guard let url = fullURL else { return nil }
        await MainActor.run { downloading = true }
        defer { Task { @MainActor in downloading = false } }

        var request = URLRequest(url: url)
        if let token = KeychainService.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[Relay] Attachment download failed: HTTP \(code)")
                return nil
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let fileURL = tmp.appendingPathComponent(attachment.filename)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            print("[Relay] Attachment download error: \(error)")
            return nil
        }
    }
}

private struct FileURLRef: Identifiable {
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

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        // Wrap so the sheet has a navigation bar with a Done button on iOS.
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
