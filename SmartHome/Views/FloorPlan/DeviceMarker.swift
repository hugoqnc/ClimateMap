import SwiftUI

struct DeviceMarker: View {
    enum Kind {
        case meter(temperature: Double, humidity: Int)
    }

    let name: String
    let kind: Kind
    let isEditing: Bool
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.78))
                    .symbolEffect(.pulse, options: .repeating, isActive: isEditing)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 49)
                        .transition(.opacity)
                } else {
                    Text(temperature, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())

                    Text("°")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .padding(.leading, -6)
                        .alignmentGuide(.firstTextBaseline) { dimensions in
                            dimensions[.firstTextBaseline] + 2
                        }
                        .transition(.opacity)
                }
            }

            if !isLoading {
                HStack(spacing: 2) {
                    Image(systemName: "humidity.fill")
                    Text("\(humidity)%")
                }
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .glassEffect(
            .regular.tint(isEditing ? .blue.opacity(0.12) : nil),
            in: .rect(cornerRadius: 14)
        )
        .shadow(color: .black.opacity(isEditing ? 0.13 : 0.08), radius: isEditing ? 10 : 7, y: 3)
        .scaleEffect(isEditing ? 1.04 : 1)
        .animation(.smooth(duration: 0.22), value: isEditing)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .contentShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var temperature: Double {
        switch kind {
        case let .meter(temperature, _): temperature
        }
    }

    private var humidity: Int {
        switch kind {
        case let .meter(_, humidity): humidity
        }
    }

    private var accessibilityText: String {
        isLoading
            ? "\(name), updating temperature"
            : "\(name), \(temperature.formatted(.number.precision(.fractionLength(1)))) degrees, \(humidity) percent humidity"
    }
}
