import SwiftUI

struct FloorPlanDrawingView: View {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let depth = max(3.0, size.width * 0.009)

            draw(
                ApartmentFloorPlan.walls,
                color: .primary,
                lineWidth: depth,
                in: &context,
                size: size
            )

            // Doors are represented architecturally as clean breaks in a wall.
            context.blendMode = .clear
            draw(
                ApartmentFloorPlan.doors,
                color: .black,
                lineWidth: depth + 2.5,
                in: &context,
                size: size
            )
            context.blendMode = .normal

            let windowColor = Color(red: 0.36, green: 0.72, blue: 0.82)
            draw(
                ApartmentFloorPlan.windows,
                color: windowColor.opacity(0.78),
                lineWidth: depth,
                in: &context,
                size: size
            )
            draw(
                ApartmentFloorPlan.windows,
                color: .white.opacity(0.72),
                lineWidth: max(0.8, depth * 0.28),
                in: &context,
                size: size
            )
        }
        .accessibilityHidden(true)
    }

    private func draw(
        _ segments: [PlanSegment],
        color: Color,
        lineWidth: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for segment in segments {
            var path = Path()
            path.move(to: segment.start.point(in: size))
            path.addLine(to: segment.end.point(in: size))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .square, lineJoin: .round)
            )
        }
    }
}
