import SwiftUI

/// A pixel-art smiley face rendered as a grid of small squares.
/// Filled background with cutout features (eyes, mouth) for an inverted look.
struct PixelFace: View {
    let frame: PixelFaceFrame
    let faceColor: Color
    let featureColor: Color
    var pixelSize: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let mask = frame.mask
            let features = frame.features
            let rows = mask.count
            let cols = mask[0].count
            let totalW = CGFloat(cols) * pixelSize
            let totalH = CGFloat(rows) * pixelSize
            let offsetX = (size.width - totalW) / 2
            let offsetY = (size.height - totalH) / 2

            for row in 0..<rows {
                for col in 0..<cols {
                    let x = offsetX + CGFloat(col) * pixelSize
                    let y = offsetY + CGFloat(row) * pixelSize
                    let rect = CGRect(x: x, y: y, width: pixelSize, height: pixelSize)

                    if mask[row][col] {
                        // Face fill
                        context.fill(Path(rect), with: .color(faceColor))
                        // Feature cutout on top
                        if features[row][col] {
                            context.fill(Path(rect), with: .color(featureColor))
                        }
                    }
                }
            }
        }
        .frame(width: CGFloat(frame.mask[0].count) * pixelSize,
               height: CGFloat(frame.mask.count) * pixelSize)
    }
}

// MARK: - Frame Data

struct PixelFaceFrame: Equatable {
    let mask: [[Bool]]       // Circle shape — true = part of face
    let features: [[Bool]]   // Eyes/mouth — true = dark cutout

    /// Create from two string grids: 'O' = face fill, '#' = feature (dark), '.' = empty
    static func from(_ rows: [String]) -> PixelFaceFrame {
        let mask = rows.map { row in row.map { $0 == "O" || $0 == "#" } }
        let features = rows.map { row in row.map { $0 == "#" } }
        return PixelFaceFrame(mask: mask, features: features)
    }
}

// MARK: - Face Library (13x13 grid)

enum PixelFaces {

    // Shared round mask for reference:
    //  ...OOOOOOO...
    //  ..OOOOOOOOO..
    //  .OOOOOOOOOOO.
    //  OOOOOOOOOOOOO
    //  OOOOOOOOOOOOO
    //  OOOOOOOOOOOOO
    //  OOOOOOOOOOOOO
    //  OOOOOOOOOOOOO
    //  OOOOOOOOOOOOO
    //  OOOOOOOOOOOOO
    //  .OOOOOOOOOOO.
    //  ..OOOOOOOOO..
    //  ...OOOOOOO...

    // ── Idle faces ──

    static let smile = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOO##OOO##OOO",
        "OOO##OOO##OOO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOO#OOOOO#OOO",
        "OOOO#####OOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let softSmile = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOO##OOO##OOO",
        "OOO##OOO##OOO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOOO#OOO#OOOO",
        "OOOOO###OOOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let neutral = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOO##OOO##OOO",
        "OOO##OOO##OOO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOO#####OOOOO",
        "OOOOOOOOOOOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let wink = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOO##OOO##OOO",
        "OOO##OOOO#OOO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOO#OOOOO#OOO",
        "OOOO#####OOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let bliss = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OO####O####OO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOO#OOOOO#OOO",
        "OOOO#####OOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let bigSmile = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOO##OOO##OOO",
        "OOO##OOO##OOO",
        "OOOOOOOOOOOOO",
        "OO#OOOOOOO#OO",
        "OOO#OOOOO#OOO",
        "OOOO#####OOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    // ── Thinking faces ──

    static let thinking = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOO##OOO##OOO",
        "OOO##OOO##OOO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOOO####OOOOO",
        "OOOOOOOOOOOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let thinkingLook = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOOO##OOO##OO",
        "OOOO##OOO##OO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOOOO####OOOO",
        "OOOOOOOOOOOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let thinkingUp = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOO##OOO##OOO",
        "OOO##OOO##OOO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOOO####OOOOO",
        "OOOOOOOOOOOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    // ── Offline faces ──

    static let sleeping = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OO####O####OO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOOO#####OOOO",
        "OOOOOOOOOOOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    static let deepSleep = PixelFaceFrame.from([
        "...OOOOOOO...",
        "..OOOOOOOOO..",
        ".OOOOOOOOOOO.",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OO####O####OO",
        "OOOOOOOOOOOOO",
        "OOOOOOOOOOOOO",
        "OOOOO###OOOOO",
        "OOOOOOOOOOOOO",
        ".OOOOOOOOOOO.",
        "..OOOOOOOOO..",
        "...OOOOOOO...",
    ])

    // MARK: - Animation Sequences

    static let idleSequence: [PixelFaceFrame] = [
        smile, smile, softSmile, smile, neutral,
        smile, bigSmile, bliss, smile, wink,
    ]

    static let thinkingSequence: [PixelFaceFrame] = [
        thinking, thinkingLook, thinking, thinkingUp, thinking, thinkingLook,
    ]

    static let offlineSequence: [PixelFaceFrame] = [
        sleeping, sleeping, deepSleep, sleeping,
    ]
}
