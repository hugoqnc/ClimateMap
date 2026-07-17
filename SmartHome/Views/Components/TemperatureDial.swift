import SwiftUI

struct TemperatureDial: View {
    let temperature: Int
    let isDisabled: Bool
    let isLoading: Bool
    let onCommit: (Int) -> Void

    @State private var preview: Int?

    private var displayedTemperature: Int { preview ?? temperature }

    var body: some View {
        GeometryReader { proxy in
            let geometry = DialGeometry(size: proxy.size, temperature: displayedTemperature)
            ZStack {
                Canvas { context, _ in
                    context.stroke(
                        geometry.fullArc,
                        with: .color(.secondary.opacity(0.16)),
                        style: StrokeStyle(lineWidth: 15, lineCap: .round)
                    )
                    context.stroke(
                        geometry.progressArc,
                        with: .linearGradient(
                            Gradient(colors: [.cyan, .blue, .indigo]),
                            startPoint: CGPoint(x: geometry.center.x - geometry.radius, y: geometry.center.y),
                            endPoint: CGPoint(x: geometry.center.x + geometry.radius, y: geometry.center.y)
                        ),
                        style: StrokeStyle(lineWidth: 15, lineCap: .round)
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: geometry.knob.x - 9, y: geometry.knob.y - 9, width: 18, height: 18)),
                        with: .color(.white)
                    )
                    context.stroke(
                        Path(ellipseIn: CGRect(x: geometry.knob.x - 9, y: geometry.knob.y - 9, width: 18, height: 18)),
                        with: .color(.blue),
                        lineWidth: 4
                    )
                }
                .contentShape(Rectangle())
                .gesture(dialGesture(geometry: geometry))

                VStack(spacing: 3) {
                    Text("\(displayedTemperature)°")
                        .font(.system(size: 64, weight: .medium, design: .rounded))
                        .contentTransition(.numericText())
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(isLoading ? "ADJUSTING" : "TARGET")
                    }
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                }
                .animation(.easeInOut(duration: 0.18), value: isLoading)
                .position(x: geometry.center.x, y: geometry.center.y - 46)

                temperatureStepper
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 27)
            }
        }
        .frame(height: 230)
        .onChange(of: temperature) { _, _ in
            preview = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target temperature")
        .accessibilityValue("\(temperature) degrees Celsius")
        .accessibilityAdjustableAction { direction in
            guard !isDisabled else { return }
            switch direction {
            case .increment: onCommit(min(30, temperature + 1))
            case .decrement: onCommit(max(16, temperature - 1))
            @unknown default: break
            }
        }
    }

    private var temperatureStepper: some View {
        HStack(spacing: 0) {
            stepButton(symbol: "minus", value: max(16, temperature - 1))

            Divider()
                .frame(height: 18)

            stepButton(symbol: "plus", value: min(30, temperature + 1))
        }
        .padding(4)
        .background(.thinMaterial, in: .capsule)
        .overlay {
            Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .opacity(isDisabled ? 0.48 : 1)
    }

    private func stepButton(symbol: String, value: Int) -> some View {
        Button {
            preview = value
            onCommit(value)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 46, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || value == temperature)
    }

    private func dialGesture(geometry: DialGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isDisabled else { return }
                preview = geometry.temperature(at: value.location)
            }
            .onEnded { value in
                guard !isDisabled else { return }
                let value = geometry.temperature(at: value.location)
                preview = value
                onCommit(value)
            }
    }
}

private struct DialGeometry {
    let size: CGSize
    let temperature: Int
    let center: CGPoint
    let radius: CGFloat
    let fullArc: Path
    let progressArc: Path
    let knob: CGPoint

    init(size: CGSize, temperature: Int) {
        self.size = size
        self.temperature = temperature
        center = CGPoint(x: size.width / 2, y: size.height * 0.72)
        radius = min(size.width * 0.39, size.height * 0.63)
        fullArc = Self.arc(center: center, radius: radius, from: .pi, to: 0)
        let progress = CGFloat(temperature - 16) / 14
        let angle = .pi * (1 - progress)
        progressArc = Self.arc(center: center, radius: radius, from: .pi, to: angle)
        knob = CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
    }

    func temperature(at point: CGPoint) -> Int {
        let raw = atan2(center.y - point.y, point.x - center.x)
        let angle = min(max(raw, 0), .pi)
        return min(max(Int((16 + (1 - angle / .pi) * 14).rounded()), 16), 30)
    }

    private static func arc(center: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) -> Path {
        var path = Path()
        let count = 60
        for step in 0...count {
            let amount = CGFloat(step) / CGFloat(count)
            let angle = start + (end - start) * amount
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
