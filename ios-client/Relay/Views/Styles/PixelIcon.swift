import SwiftUI

/// Renders a small pixel-art icon from a grid.
struct PixelIcon: View {
    let grid: [[Bool]]
    let color: Color
    var pixelSize: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            let rows = grid.count
            let cols = grid[0].count
            let totalW = CGFloat(cols) * pixelSize
            let totalH = CGFloat(rows) * pixelSize
            let offsetX = (size.width - totalW) / 2
            let offsetY = (size.height - totalH) / 2

            for row in 0..<rows {
                for col in 0..<cols {
                    if grid[row][col] {
                        let rect = CGRect(
                            x: offsetX + CGFloat(col) * pixelSize,
                            y: offsetY + CGFloat(row) * pixelSize,
                            width: pixelSize,
                            height: pixelSize
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .frame(width: CGFloat(grid[0].count) * pixelSize,
               height: CGFloat(grid.count) * pixelSize)
    }

    /// Convenience: create from string grid where '#' = on
    static func from(_ rows: [String], color: Color, pixelSize: CGFloat = 2.5) -> PixelIcon {
        let grid = rows.map { row in row.map { $0 == "#" } }
        return PixelIcon(grid: grid, color: color, pixelSize: pixelSize)
    }
}

// MARK: - Icon Library

enum PixelIcons {
    // Hamburger menu (9x7)
    static func hamburger(color: Color, size: CGFloat = 2.5) -> PixelIcon {
        .from([
            "#########",
            ".........",
            ".........",
            "#########",
            ".........",
            ".........",
            "#########",
        ], color: color, pixelSize: size)
    }

    // Sound wave (9x9)
    static func waveform(color: Color, size: CGFloat = 2.5) -> PixelIcon {
        .from([
            "....#....",
            "..#.#.#..",
            "..#.#.#..",
            "#.#.#.#.#",
            "#.#.#.#.#",
            "#.#.#.#.#",
            "..#.#.#..",
            "..#.#.#..",
            "....#....",
        ], color: color, pixelSize: size)
    }

    // Return/enter arrow ⏎ (11x11)
    // Line goes down on right, turns left, big arrowhead points left
    static func returnArrow(color: Color, size: CGFloat = 2.5) -> PixelIcon {
        .from([
            "..........#",
            "..........#",
            "..........#",
            "..........#",
            "..#.......#",
            ".##.......#",
            "###########",
            ".##........",
            "..#........",
        ], color: color, pixelSize: size)
    }

    // Kebab / vertical dots (3x9)
    static func kebab(color: Color, size: CGFloat = 3.5) -> PixelIcon {
        .from([
            "###",
            "###",
            "...",
            "###",
            "###",
            "...",
            "###",
            "###",
        ], color: color, pixelSize: size)
    }

    // X / close (7x7)
    static func xMark(color: Color, size: CGFloat = 2.5) -> PixelIcon {
        .from([
            "#.....#",
            ".#...#.",
            "..#.#..",
            "...#...",
            "..#.#..",
            ".#...#.",
            "#.....#",
        ], color: color, pixelSize: size)
    }

    // Mic (7x9)
    static func mic(color: Color, size: CGFloat = 2.5) -> PixelIcon {
        .from([
            "..###..",
            "..###..",
            "..###..",
            "..###..",
            ".#####.",
            ".#.#.#.",
            "..###..",
            "...#...",
            ".#####.",
        ], color: color, pixelSize: size)
    }

    // Gear (11x11)
    static func gear(color: Color, size: CGFloat = 3) -> PixelIcon {
        .from([
            "...##.##...",
            ".#########.",
            "###.###.###",
            "##..###..##",
            "####...####",
            "##.......##",
            "####...####",
            "##..###..##",
            "###.###.###",
            ".#########.",
            "...##.##...",
        ], color: color, pixelSize: size)
    }

    // Mic muted (7x9)
    static func micMuted(color: Color, size: CGFloat = 2.5) -> PixelIcon {
        .from([
            "..###.#",
            "..####.",
            "..###..",
            ".####..",
            "####.#.",
            ".#.#.#.",
            "..###..",
            "...#...",
            ".#####.",
        ], color: color, pixelSize: size)
    }
}
