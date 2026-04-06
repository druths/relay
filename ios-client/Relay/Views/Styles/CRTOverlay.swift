import SwiftUI

/// Retro CRT monitor effect: scanlines + edge vignette.
/// Only rendered when the current theme enables it.
struct CRTOverlay: View {
    @Environment(\.relayTheme) private var theme

    var body: some View {
        ZStack {
            if theme.showScanlines {
                Scanlines()
                    .allowsHitTesting(false)
            }
            if theme.showCRTVignette {
                Vignette()
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Scanlines

private struct Scanlines: View {
    var body: some View {
        Canvas { context, size in
            let lineHeight: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1.5)
                context.fill(Path(rect), with: .color(.black.opacity(0.08)))
                y += lineHeight
            }
        }
    }
}

// MARK: - Vignette

private struct Vignette: View {
    @Environment(\.relayTheme) private var theme

    private var intensity: Double {
        // Mono themes get a slightly stronger vignette
        theme.bubbleBorderColor != nil ? 0.35 : 0.25
    }

    var body: some View {
        RadialGradient(
            gradient: Gradient(colors: [
                .clear,
                .clear,
                .black.opacity(intensity * 0.5),
                .black.opacity(intensity),
            ]),
            center: .center,
            startRadius: 300,
            endRadius: 700
        )
    }
}
