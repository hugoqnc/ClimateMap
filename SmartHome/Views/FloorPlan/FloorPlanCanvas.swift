import SwiftUI

struct FloorPlanCanvas: View {
    @Bindable var model: HomeModel
    let isEditing: Bool

    @State private var field: DiffusionField?
    @State private var heatmapRevision = 0

    private var heatmapKey: HeatmapRefreshKey {
        HeatmapRefreshKey(meters: model.meters, revision: heatmapRevision)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                TemperatureHeatmapView(
                    field: model.readingsAreStale || !model.hasCompleteMeterData ? nil : field
                )
                    .clipShape(ApartmentOutlineShape())
                FloorPlanDrawingView()

                ForEach(ApartmentFloorPlan.rooms) { room in
                    RoomNameLabel(name: room.name)
                        .position(room.position.point(in: size))
                        .allowsHitTesting(false)
                }

                ForEach(model.meters) { meter in
                    if let position = model.position(for: meter.id) {
                        DeviceMarker(
                            name: meter.name,
                            kind: .meter(temperature: meter.temperature, humidity: meter.humidity),
                            isEditing: isEditing,
                            isLoading: model.readingsAreStale || !meter.isAvailable
                        )
                        .position(position.point(in: size))
                        .allowsHitTesting(isEditing)
                        .gesture(dragGesture(deviceID: meter.id, size: size))
                    }
                }

                if let field, !model.readingsAreStale, model.hasCompleteMeterData {
                    VStack {
                        HStack(spacing: 8) {
                            Text(field.minimum, format: .number.precision(.fractionLength(1)))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [.blue, .cyan, Color(red: 0.91, green: 0.94, blue: 0.87), .orange, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: 92, height: 7)
                            Text(field.maximum, format: .number.precision(.fractionLength(1)))
                        }
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .glassEffect(.clear, in: .capsule)
                        Spacer()
                    }
                    .padding(12)
                    .offset(y: -32)
                }
            }
            .coordinateSpace(name: "floor-plan")
        }
        .aspectRatio(ApartmentFloorPlan.aspectRatio, contentMode: .fit)
        .task(id: heatmapKey) {
            await recomputeHeatmap()
        }
    }

    private func dragGesture(deviceID: String, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("floor-plan"))
            .onChanged { value in
                let point = PlanPoint(
                    x: value.location.x / size.width,
                    y: value.location.y / size.height
                )
                guard ApartmentFloorPlan.contains(point) else { return }
                model.setPosition(point, for: deviceID, persist: false)
            }
            .onEnded { _ in
                model.persistPositions()
                heatmapRevision += 1
            }
    }

    private func recomputeHeatmap() async {
        guard !model.readingsAreStale, model.hasCompleteMeterData else {
            field = nil
            return
        }
        let meters = model.meters
        let positions = model.state.positions
        let updatedField = await Task.detached(priority: .userInitiated) {
            TemperatureDiffusion.make(meters: meters, positions: positions)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            field = updatedField
        }
    }
}

private struct HeatmapRefreshKey: Hashable {
    let meters: [MeterReading]
    let revision: Int
}

private struct ApartmentOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = ApartmentFloorPlan.outline.first else { return path }
        path.move(to: first.point(in: rect.size))
        for point in ApartmentFloorPlan.outline.dropFirst() {
            path.addLine(to: point.point(in: rect.size))
        }
        path.closeSubpath()
        return path
    }
}

private struct RoomNameLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.primary.opacity(0.76))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassEffect(.clear, in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}
