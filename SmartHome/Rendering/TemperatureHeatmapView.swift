import SwiftUI

struct TemperatureHeatmapView: View {
    @Environment(\.colorScheme) private var colorScheme

    let field: DiffusionField?

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            guard let field else { return }
            let cellWidth = size.width / Double(field.width)
            let cellHeight = size.height / Double(field.height)
            for y in 0..<field.height {
                for x in 0..<field.width {
                    let value = field.normalized[y * field.width + x]
                    guard value.isFinite else { continue }
                    let rect = CGRect(
                        x: Double(x) * cellWidth,
                        y: Double(y) * cellHeight,
                        width: cellWidth + 0.35,
                        height: cellHeight + 0.35
                    )
                    context.fill(Path(rect), with: .color(HeatPalette.color(at: value)))
                }
            }
        }
        .opacity(colorScheme == .dark ? 0.44 : 0.68)
        .animation(.easeInOut(duration: 0.25), value: colorScheme)
        .accessibilityHidden(true)
    }
}

enum HeatPalette {
    private static let colors: [(Double, Double, Double)] = [
        (0.10, 0.35, 0.72),
        (0.23, 0.65, 0.88),
        (0.91, 0.94, 0.87),
        (0.97, 0.61, 0.28),
        (0.82, 0.22, 0.16),
    ]

    static func color(at value: Double) -> Color {
        let scaled = min(max(value, 0), 0.999_999) * Double(colors.count - 1)
        let index = Int(scaled)
        let amount = scaled - Double(index)
        let start = colors[index]
        let end = colors[index + 1]
        return Color(
            red: start.0 + (end.0 - start.0) * amount,
            green: start.1 + (end.1 - start.1) * amount,
            blue: start.2 + (end.2 - start.2) * amount
        )
    }
}
