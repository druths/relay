import SwiftUI

struct StatusOrb: View {
    let activeSpeaker: String
    let status: String
    let connected: Bool
    var compact: Bool = false

    @Environment(\.relayTheme) private var theme
    @State private var isPulsing = false
    @State private var spriteFrame = 0
    @State private var spriteTask: Task<Void, Never>?

    private var orbColor: Color {
        guard connected else { return theme.textQuaternary }
        return activeSpeaker == "operator" ? theme.primaryLight : theme.success
    }

    private var label: String {
        guard connected else { return "OFFLINE" }
        let name = activeSpeaker.uppercased()
        return status == "processing" ? "\(name) THINKING" : name
    }

    private var circleSize: CGFloat { compact ? 32 : 64 }
    private var shadowRadius: CGFloat { compact ? 6 : 12 }
    private var pulseScale: CGFloat { compact ? 1.1 : 1.15 }

    var body: some View {
        VStack(spacing: 8) {
            if theme.pixelIndicators {
                pixelSprite
            } else {
                classicOrb
            }

            if !compact {
                Text(label)
                    .font(theme.labelFont(size: 12))
                    .tracking(1.5)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .onChange(of: status) { _, newValue in
            isPulsing = newValue == "processing"
        }
        .onAppear {
            isPulsing = status == "processing"
        }
    }

    // MARK: - Classic Orb (default theme)

    private var classicOrb: some View {
        Circle()
            .fill(orbColor)
            .frame(width: circleSize, height: circleSize)
            .shadow(color: orbColor.opacity(0.5), radius: shadowRadius)
            .scaleEffect(shouldPulse ? pulseScale : 1.0)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                    : .default,
                value: shouldPulse
            )
    }

    // MARK: - Pixel Face Sprite (TVA themes)

    private var faceSequence: [PixelFaceFrame] {
        guard connected else { return PixelFaces.offlineSequence }
        return shouldPulse ? PixelFaces.thinkingSequence : PixelFaces.idleSequence
    }

    private var currentFrame: PixelFaceFrame {
        let seq = faceSequence
        return seq[spriteFrame % seq.count]
    }

    private var pixelSize: CGFloat {
        compact ? 2.5 : 4.5
    }

    private var pixelSprite: some View {
        PixelFace(frame: currentFrame, faceColor: orbColor, featureColor: theme.background, pixelSize: pixelSize)
            .shadow(color: orbColor.opacity(0.4), radius: compact ? 4 : 8)
            .onAppear { restartSpriteLoop() }
            .onDisappear { spriteTask?.cancel() }
            .onChange(of: connected) { _, _ in
                spriteFrame = 0
                restartSpriteLoop()
            }
            .onChange(of: shouldPulse) { _, _ in
                spriteFrame = 0
                restartSpriteLoop()
            }
    }

    private func restartSpriteLoop() {
        spriteTask?.cancel()
        spriteTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(shouldPulse ? 800 : 2000))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.3)) {
                    spriteFrame += 1
                }
            }
        }
    }

    private var shouldPulse: Bool {
        connected && isPulsing
    }
}
