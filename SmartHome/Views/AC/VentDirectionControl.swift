import SwiftUI

private enum VentModeChoice: String, CaseIterable, Identifiable {
    case off = "Closed"
    case automatic = "Auto"
    case manual = "Fixed"

    var id: Self { self }
}

struct VentDirectionControl: View {
    @Bindable var model: HomeModel
    let isAvailable: Bool

    @State private var targetPosition = 0.5
    @State private var isDragging = false
    @State private var isChoosingManualPosition = false

    private var controlsEnabled: Bool {
        isAvailable && !model.isSendingCommand
    }

    private var isAnimating: Bool {
        model.ventControlOperation?.stage == .returningOff
            || model.ventControlOperation?.stage == .positioning
            || model.ventControlOperation?.automaticStartedAt != nil
            || (model.state.ac.isOn
                && model.state.ac.oscillation == .dynamic
                && model.state.ac.oscillationStartedAt != nil)
    }

    private var showsManualControls: Bool {
        if let requestedMode = model.requestedVentMode {
            return requestedMode == .fixed
        }
        if let requestedMode = model.ventControlOperation?.requestedMode {
            return requestedMode == .fixed
        }
        return isChoosingManualPosition
            || model.state.ac.oscillation == .fixed
    }

    var body: some View {
        VStack(spacing: 13) {
            HStack {
                Label("Air direction", systemImage: "arrow.up.and.down")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimating)) { timeline in
                let livePosition = model.ventPosition(at: timeline.date)

                VentSideProfileView(
                    livePosition: livePosition,
                    targetPosition: targetPosition,
                    isOff: !model.state.ac.isOn || model.state.ac.oscillation == .none,
                    isMoving: isAnimating,
                    showsControl: showsManualControls,
                    isInteractive: controlsEnabled && model.ventControlOperation == nil,
                    isDragging: isDragging,
                    loadingTitle: model.ventControlOperation.map {
                        operationTitle($0, at: timeline.date)
                    },
                    onDragChanged: { position in
                        targetPosition = position
                        isDragging = true
                        isChoosingManualPosition = true
                    },
                    onDragEnded: { position in
                        targetPosition = position
                        isDragging = false
                        isChoosingManualPosition = true
                        Task { await model.setFixedVentPosition(position) }
                    }
                )
            }
            .frame(height: 224)

            modeSelector
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .smartHomeGlass(cornerRadius: 28)
        .opacity(isAvailable ? 1 : 0.46)
        .onAppear {
            targetPosition = min(max(model.state.ac.fixedVentPosition ?? 0.5, 0), 1)
        }
        .onChange(of: model.state.ac.fixedVentPosition) { _, newPosition in
            guard let newPosition else { return }
            targetPosition = min(max(newPosition, 0), 1)
        }
        .onChange(of: model.state.ac.oscillation) { _, mode in
            if mode == .fixed {
                isChoosingManualPosition = false
            } else if model.ventControlOperation == nil && !isChoosingManualPosition {
                isDragging = false
            }
        }
        .animation(.smooth(duration: 0.25), value: model.state.ac.oscillation)
        .animation(.smooth(duration: 0.2), value: model.ventControlOperation)
        .animation(.smooth(duration: 0.2), value: showsManualControls)
    }

    private var modeSelector: some View {
        Picker("Air direction mode", selection: modeBinding) {
            ForEach(VentModeChoice.allCases) { choice in
                Text(choice.rawValue).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!controlsEnabled || model.ventControlOperation != nil)
    }

    private var modeBinding: Binding<VentModeChoice> {
        Binding(
            get: {
                if let requestedMode = model.requestedVentMode {
                    switch requestedMode {
                    case .none: return .off
                    case .dynamic: return .automatic
                    case .fixed: return .manual
                    }
                }
                if let requestedMode = model.ventControlOperation?.requestedMode {
                    switch requestedMode {
                    case .none: return .off
                    case .dynamic: return .automatic
                    case .fixed: return .manual
                    }
                }
                if showsManualControls { return .manual }
                switch model.state.ac.oscillation {
                case .none: return .off
                case .dynamic: return .automatic
                case .fixed: return .manual
                }
            },
            set: { choice in
                switch choice {
                case .off:
                    isChoosingManualPosition = false
                    Task { await model.setOscillation(.none) }
                case .automatic:
                    isChoosingManualPosition = false
                    Task { await model.setOscillation(.dynamic) }
                case .manual:
                    guard model.state.ac.oscillation != .fixed else { return }
                    targetPosition = min(max(model.ventPosition(at: Date()), 0), 1)
                    isChoosingManualPosition = true
                }
            }
        )
    }

    private var statusBadge: some View {
        Text(statusTitle)
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(statusTint)
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(statusTint.opacity(0.12), in: .capsule)
    }

    private var statusTitle: String {
        if let operation = model.ventControlOperation {
            switch operation.stage {
            case .returningOff: return "CLOSING"
            case .synchronizing: return "SYNCING"
            case .positioning: return "MOVING"
            }
        }
        if let requestedMode = model.requestedVentMode {
            switch requestedMode {
            case .none: return "CLOSED"
            case .dynamic: return "AUTO"
            case .fixed: return "FIXED"
            }
        }
        switch model.state.ac.oscillation {
        case .none: return "CLOSED"
        case .dynamic: return "AUTO"
        case .fixed: return "FIXED"
        }
    }

    private var statusTint: Color {
        if model.ventControlOperation != nil { return .cyan }
        if let requestedMode = model.requestedVentMode {
            switch requestedMode {
            case .none: return .secondary
            case .dynamic: return .cyan
            case .fixed: return .indigo
            }
        }
        guard model.state.ac.isOn else { return .secondary }
        switch model.state.ac.oscillation {
        case .none: return .secondary
        case .dynamic: return .cyan
        case .fixed: return .indigo
        }
    }

    private func operationTitle(_ operation: VentControlOperation, at date: Date) -> String {
        switch operation.stage {
        case .returningOff:
            return "Closing vent"
        case .synchronizing:
            return "Initializing vent"
        case .positioning:
            if let automaticStartedAt = operation.automaticStartedAt,
               date.timeIntervalSince(automaticStartedAt)
                   < VentOscillationTiming.preparationDuration
                    + VentOscillationTiming.commandExecutionDelay {
                return "Initializing vent"
            }
            return "Moving to target"
        }
    }

}

private struct VentSideProfileView: View {
    let livePosition: Double
    let targetPosition: Double
    let isOff: Bool
    let isMoving: Bool
    let showsControl: Bool
    let isInteractive: Bool
    let isDragging: Bool
    let loadingTitle: String?
    let onDragChanged: (Double) -> Void
    let onDragEnded: (Double) -> Void

    private let minimumAngle = 4.0
    private let maximumAngle = 72.0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let normalizedLivePosition = min(max(livePosition, 0), 1)
            let normalizedTargetPosition = min(max(targetPosition, 0), 1)
            let liveAngle = minimumAngle
                + normalizedLivePosition * (maximumAngle - minimumAngle)
            let targetAngle = minimumAngle
                + normalizedTargetPosition * (maximumAngle - minimumAngle)
            let hinge = CGPoint(x: size.width * 0.22, y: size.height * 0.69)
            let bladeLength = min(size.width * 0.52, size.height * 0.64)
            let bladeEnd = point(from: hinge, radius: bladeLength, angle: liveAngle)
            let controlRadius = bladeLength + 10
            let targetHandle = point(from: hinge, radius: controlRadius, angle: targetAngle)

            ZStack {
                acBody(size: size)

                ventSupport(from: hinge, to: bladeEnd)

                secondaryVentBlade(from: hinge, to: bladeEnd, angle: liveAngle)

                ventBlade(from: hinge, to: bladeEnd, angle: liveAngle)

                Circle()
                    .fill(Color(.systemGray4))
                    .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 1))
                    .overlay {
                        Circle()
                            .fill(Color(.systemGray2))
                            .frame(width: 7, height: 7)
                    }
                    .frame(width: 27, height: 27)
                    .position(hinge)

                if showsControl {
                    controlArc(hinge: hinge, radius: controlRadius, size: size)
                        .transition(.opacity)

                    targetGuide(from: hinge, to: targetHandle, radius: controlRadius)

                    controlHandle(
                        at: targetHandle,
                        normalizedPosition: normalizedTargetPosition,
                        hinge: hinge
                    )
                        .transition(.scale.combined(with: .opacity))
                }

                if let loadingTitle {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.blue)
                        Text(loadingTitle)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 29)
                    .background(.regularMaterial, in: .capsule)
                    .overlay {
                        Capsule().stroke(.primary.opacity(0.08), lineWidth: 0.75)
                    }
                    .position(x: size.width * 0.24, y: size.height * 0.85)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .coordinateSpace(name: "ventSideProfile")
            .animation(.linear(duration: 0.08), value: normalizedLivePosition)
            .animation(isDragging ? nil : .smooth(duration: 0.2), value: normalizedTargetPosition)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Air conditioner vent")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(showsControl ? "Drag the position handle and release to set" : "")
    }

    private var accessibilityValue: String {
        if isOff { return "Closed" }
        if isMoving { return "Oscillating automatically" }
        return "Fixed, live vent \(Int((livePosition * 100).rounded())) percent, target \(Int((targetPosition * 100).rounded())) percent"
    }

    private func acBody(size: CGSize) -> some View {
        let bodyWidth = size.width * 0.98
        let bodyHeight = size.height * 0.32
        let accessoryY = size.height * 0.85 - (size.height - bodyHeight)

        return ZStack {
            ACBodyProfileShape()
                .fill(Color(.secondarySystemBackground))
                .overlay {
                    ACBodyProfileShape()
                        .stroke(.primary.opacity(0.16), lineWidth: 1)
                }

            Capsule()
                .fill(.black.opacity(0.62))
                .frame(width: size.width * 0.57, height: 10)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(0.16))
                        .frame(height: 1)
                }
                .position(x: size.width * 0.53, y: 8)

            Image(systemName: "air.conditioner")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.34))
                .position(x: size.width * 0.87, y: accessoryY)
        }
        .frame(width: bodyWidth, height: bodyHeight)
        .position(x: size.width / 2, y: size.height - bodyHeight / 2)
    }

    private func ventBlade(from start: CGPoint, to end: CGPoint, angle: Double) -> some View {
        let radians = angle * .pi / 180
        let normal = CGPoint(x: sin(radians), y: cos(radians))
        let startHalfThickness = 8.0
        let endHalfThickness = 6.0

        return Path { path in
            path.move(to: CGPoint(
                x: start.x - normal.x * startHalfThickness,
                y: start.y - normal.y * startHalfThickness
            ))
            path.addLine(to: CGPoint(
                x: end.x - normal.x * endHalfThickness,
                y: end.y - normal.y * endHalfThickness
            ))
            path.addQuadCurve(
                to: CGPoint(
                    x: end.x + normal.x * endHalfThickness,
                    y: end.y + normal.y * endHalfThickness
                ),
                control: point(from: end, radius: 7, angle: angle)
            )
            path.addLine(to: CGPoint(
                x: start.x + normal.x * startHalfThickness,
                y: start.y + normal.y * startHalfThickness
            ))
            path.closeSubpath()
        }
        .fill(Color(.systemGray4))
        .overlay {
            Path { path in
                path.move(to: CGPoint(
                    x: start.x - normal.x * startHalfThickness,
                    y: start.y - normal.y * startHalfThickness
                ))
                path.addLine(to: CGPoint(
                    x: end.x - normal.x * endHalfThickness,
                    y: end.y - normal.y * endHalfThickness
                ))
            }
            .stroke(.primary.opacity(0.25), lineWidth: 1)
        }
    }

    private func secondaryVentBlade(
        from start: CGPoint,
        to end: CGPoint,
        angle: Double
    ) -> some View {
        let radians = angle * .pi / 180
        let normal = CGPoint(x: sin(radians), y: cos(radians))
        let shortenedEnd = CGPoint(
            x: start.x + (end.x - start.x) * 0.84,
            y: start.y + (end.y - start.y) * 0.84
        )
        let offset = 9.0
        let shiftedStart = CGPoint(
            x: start.x + normal.x * offset,
            y: start.y + normal.y * offset
        )
        let shiftedEnd = CGPoint(
            x: shortenedEnd.x + normal.x * offset,
            y: shortenedEnd.y + normal.y * offset
        )
        let halfThickness = 4.5

        return Path { path in
            path.move(to: CGPoint(
                x: shiftedStart.x - normal.x * halfThickness,
                y: shiftedStart.y - normal.y * halfThickness
            ))
            path.addLine(to: CGPoint(
                x: shiftedEnd.x - normal.x * halfThickness,
                y: shiftedEnd.y - normal.y * halfThickness
            ))
            path.addQuadCurve(
                to: CGPoint(
                    x: shiftedEnd.x + normal.x * halfThickness,
                    y: shiftedEnd.y + normal.y * halfThickness
                ),
                control: point(from: shiftedEnd, radius: 5, angle: angle)
            )
            path.addLine(to: CGPoint(
                x: shiftedStart.x + normal.x * halfThickness,
                y: shiftedStart.y + normal.y * halfThickness
            ))
            path.closeSubpath()
        }
        .fill(Color(.systemGray5))
        .overlay {
            Path { path in
                path.move(to: shiftedStart)
                path.addLine(to: shiftedEnd)
            }
            .stroke(.primary.opacity(0.18), lineWidth: 0.8)
        }
    }

    private func ventSupport(from start: CGPoint, to end: CGPoint) -> some View {
        let alongBlade = CGPoint(
            x: start.x + (end.x - start.x) * 0.55,
            y: start.y + (end.y - start.y) * 0.55
        )
        let bodyAnchor = CGPoint(
            x: start.x + max(31, (end.x - start.x) * 0.38),
            y: start.y + 1
        )

        return Path { path in
            path.move(to: CGPoint(x: start.x + 7, y: start.y))
            path.addLine(to: CGPoint(x: alongBlade.x + 5, y: alongBlade.y + 9))
            path.addLine(to: bodyAnchor)
            path.closeSubpath()
        }
        .fill(Color(.systemGray5))
        .overlay {
            Path { path in
                path.move(to: CGPoint(x: start.x + 7, y: start.y))
                path.addLine(to: CGPoint(x: alongBlade.x + 5, y: alongBlade.y + 9))
                path.addLine(to: bodyAnchor)
            }
            .stroke(.primary.opacity(0.17), lineWidth: 0.8)
        }
    }

    private func controlArc(hinge: CGPoint, radius: Double, size: CGSize) -> some View {
        Canvas { context, _ in
            let start = minimumAngle * .pi / 180
            let end = maximumAngle * .pi / 180
            var arc = Path()
            arc.addArc(
                center: hinge,
                radius: radius,
                startAngle: .radians(-end),
                endAngle: .radians(-start),
                clockwise: false
            )
            context.stroke(arc, with: .color(.secondary.opacity(0.38)), lineWidth: 1.5)

            for step in 0...6 {
                let amount = Double(step) / 6
                let tickAngle = start + amount * (end - start)
                var tick = Path()
                tick.move(to: point(from: hinge, radius: radius - 5, radians: tickAngle))
                tick.addLine(to: point(from: hinge, radius: radius + 5, radians: tickAngle))
                context.stroke(tick, with: .color(.secondary.opacity(0.42)), lineWidth: 1.25)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func targetGuide(from start: CGPoint, to end: CGPoint, radius: Double) -> some View {
        Path { path in
            path.move(to: point(from: start, radius: 18, angle: targetAngle(from: start, to: end)))
            path.addLine(to: point(
                from: start,
                radius: max(22, radius - 18),
                angle: targetAngle(from: start, to: end)
            ))
        }
        .stroke(
            .blue.opacity(0.52),
            style: StrokeStyle(lineWidth: 1.25, dash: [4, 4])
        )
    }

    private func controlHandle(
        at location: CGPoint,
        normalizedPosition: Double,
        hinge: CGPoint
    ) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(isDragging ? 0.22 : 0.13))
                    .overlay(Circle().stroke(.blue.opacity(0.32), lineWidth: 1))
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.blue)
            }
            .frame(width: isDragging ? 34 : 30, height: isDragging ? 34 : 30)

            Text("Target \(Int((normalizedPosition * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.blue)
        }
        .padding(.leading, 3)
        .padding(.trailing, 9)
        .frame(height: isDragging ? 40 : 36)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule().stroke(.blue.opacity(0.16), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .contentShape(Capsule())
        .position(x: location.x + 40, y: max(24, location.y - 12))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("ventSideProfile"))
                .onChanged { value in
                    guard isInteractive else { return }
                    onDragChanged(position(for: value.location, around: hinge))
                }
                .onEnded { value in
                    guard isInteractive else { return }
                    onDragEnded(position(for: value.location, around: hinge))
                }
        )
        .allowsHitTesting(isInteractive)
        .animation(.snappy(duration: 0.16), value: isDragging)
    }

    private func position(for location: CGPoint, around hinge: CGPoint) -> Double {
        let dx = max(1, location.x - hinge.x)
        let dy = hinge.y - location.y
        let angle = atan2(dy, dx) * 180 / .pi
        return min(max((angle - minimumAngle) / (maximumAngle - minimumAngle), 0), 1)
    }

    private func targetAngle(from start: CGPoint, to end: CGPoint) -> Double {
        atan2(start.y - end.y, end.x - start.x) * 180 / .pi
    }

    private func point(from origin: CGPoint, radius: Double, angle: Double) -> CGPoint {
        point(from: origin, radius: radius, radians: angle * .pi / 180)
    }

    private func point(from origin: CGPoint, radius: Double, radians: Double) -> CGPoint {
        CGPoint(
            x: origin.x + cos(radians) * radius,
            y: origin.y - sin(radians) * radius
        )
    }
}

private struct ACBodyProfileShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulderWidth = min(rect.width * 0.19, 64)
        let shoulderDepth = min(rect.height * 0.58, 54)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 8))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 10, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulderWidth, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + shoulderDepth),
            control1: CGPoint(x: rect.maxX - shoulderWidth * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + shoulderDepth * 0.30)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
