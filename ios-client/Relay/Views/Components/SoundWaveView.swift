import SwiftUI

struct SoundWaveView: View {
    var meteringLevel: Float
    var barCount: Int = 5

    @Environment(\.relayTheme) private var theme
    @State private var offsets: [Double] = []

    private var normalizedLevel: Double {
        // Map dB range (-60...0) to 0...1, clamp
        let clamped = max(min(Double(meteringLevel), 0), -60)
        return (clamped + 60) / 60
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let offset = index < offsets.count ? offsets[index] : 0
                let barLevel = max(0.08, min(1.0, normalizedLevel + offset * normalizedLevel))
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.primary)
                    .frame(width: 4, height: 4 + barLevel * 28)
                    .animation(.easeInOut(duration: 0.12), value: barLevel)
            }
        }
        .frame(height: 36)
        .onAppear {
            offsets = (0..<barCount).map { _ in Double.random(in: -0.3...0.3) }
        }
        .onChange(of: meteringLevel) {
            offsets = (0..<barCount).map { _ in Double.random(in: -0.3...0.3) }
        }
    }
}
