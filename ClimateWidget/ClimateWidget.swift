import AppIntents
import SwiftUI
import WidgetKit

struct ClimateWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let state: WidgetHomeState
    let roomTemperature: Double?
    let temperatureDate: Date?
}

struct ClimateWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClimateWidgetEntry {
        ClimateWidgetEntry(
            date: Date(),
            state: WidgetHomeState(),
            roomTemperature: 22.4,
            temperatureDate: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ClimateWidgetEntry) -> Void) {
        completion(cachedEntry())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping @Sendable (Timeline<ClimateWidgetEntry>) -> Void
    ) {
        Task {
            let entry = await refreshedEntry()
            let now = Date()
            let entries = (0...15).map { minute in
                ClimateWidgetEntry(
                    date: now.addingTimeInterval(Double(minute) * 60),
                    state: entry.state,
                    roomTemperature: entry.roomTemperature,
                    temperatureDate: entry.temperatureDate
                )
            }
            completion(Timeline(
                entries: entries,
                policy: .after(now.addingTimeInterval(15 * 60))
            ))
        }
    }

    private func cachedEntry() -> ClimateWidgetEntry {
        let cache = WidgetSharedStore.loadCache()
        return ClimateWidgetEntry(
            date: Date(),
            state: WidgetSharedStore.loadState(),
            roomTemperature: cache?.roomTemperature,
            temperatureDate: cache?.updatedAt
        )
    }

    private func refreshedEntry() async -> ClimateWidgetEntry {
        let state = WidgetSharedStore.loadState()
        let cache = WidgetSharedStore.loadCache()
        if let cache,
           cache.meterID == state.linkedMeterID,
           Date().timeIntervalSince(cache.updatedAt) < 60 {
            return ClimateWidgetEntry(
                date: Date(),
                state: state,
                roomTemperature: cache.roomTemperature,
                temperatureDate: cache.updatedAt
            )
        }

        do {
            let client = try WidgetClimateService.client()
            let devices = try await client.devices()
            let meterID = state.linkedMeterID
                ?? cache?.meterID
                ?? devices.deviceList.first(where: \WidgetDevice.isMeter)?.deviceId
            let remoteID = devices.infraredRemoteList.first(where: {
                $0.remoteType.localizedCaseInsensitiveCompare("Others") == .orderedSame
            })?.deviceId ?? cache?.remoteID
            guard let meterID, let remoteID else { return cachedEntry() }
            let status = try await client.meterStatus(deviceID: meterID)
            guard status.isPlausible else { return cachedEntry() }
            let updatedCache = WidgetClimateCache(
                roomTemperature: status.temperature,
                updatedAt: Date(),
                remoteID: remoteID,
                meterID: meterID
            )
            WidgetSharedStore.saveCache(updatedCache)
            return ClimateWidgetEntry(
                date: Date(),
                state: state,
                roomTemperature: updatedCache.roomTemperature,
                temperatureDate: updatedCache.updatedAt
            )
        } catch {
            return cachedEntry()
        }
    }
}

struct ClimateWidgetView: View {
    let entry: ClimateWidgetEntry

    @Environment(\.colorScheme) private var colorScheme

    private var canAdjustTemperature: Bool {
        entry.state.ac.isOn && !entry.state.ac.eco
    }

    private var canToggleSilence: Bool {
        entry.state.ac.isOn && !entry.state.ac.eco
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 8) {
                targetGauge
                HStack(spacing: 18) {
                    temperatureButton(
                        symbol: "minus",
                        enabled: canAdjustTemperature
                            && entry.state.ac.targetTemperature > WidgetTemperatureRange.minimum,
                        intent: DecreaseClimateTemperatureIntent()
                    )
                    temperatureButton(
                        symbol: "plus",
                        enabled: canAdjustTemperature
                            && entry.state.ac.targetTemperature < WidgetTemperatureRange.maximum,
                        intent: IncreaseClimateTemperatureIntent()
                    )
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 9) {
                roomTemperature
                powerButton
                silenceButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .containerBackground(for: .widget) {
            ZStack {
                Color(.systemBackground)
                RadialGradient(
                    colors: [
                        roomTemperatureTint.opacity(colorScheme == .dark ? 0.48 : 0.38),
                        roomTemperatureTint.opacity(colorScheme == .dark ? 0.24 : 0.18),
                        roomTemperatureTint.opacity(colorScheme == .dark ? 0.09 : 0.07),
                        .clear
                    ],
                    center: UnitPoint(x: 0.74, y: 0.24),
                    startRadius: 2,
                    endRadius: 300
                )
            }
        }
        .widgetURL(URL(string: "queinnec-smarthome://climate"))
    }

    private var targetGauge: some View {
        ZStack(alignment: .bottom) {
            WidgetGaugeArc(progress: 1)
                .stroke(.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 10, lineCap: .round))
            WidgetGaugeArc(progress: gaugeProgress)
                .stroke(
                    LinearGradient(colors: [.cyan, .blue, .indigo], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
            VStack(spacing: 0) {
                Text(gaugeText)
                    .font(.system(size: entry.state.ac.eco ? 25 : 38, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.7)
                Text(gaugeCaption)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 1)
        }
        .frame(height: 76)
        .opacity(entry.state.ac.isOn ? 1 : 0.46)
    }

    private var gaugeProgress: Double {
        guard entry.state.ac.isOn, !entry.state.ac.eco else { return 0 }
        let range = WidgetTemperatureRange.maximum - WidgetTemperatureRange.minimum
        return Double(entry.state.ac.targetTemperature - WidgetTemperatureRange.minimum)
            / Double(range)
    }

    private var gaugeText: String {
        if !entry.state.ac.isOn { return "OFF" }
        if entry.state.ac.eco { return "ECO" }
        return "\(entry.state.ac.targetTemperature)°"
    }

    private var gaugeCaption: String {
        entry.state.ac.eco ? "AUTOMATIC" : "TARGET"
    }

    private var roomTemperature: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text("ROOM")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let date = entry.temperatureDate {
                    Text(readingAge(since: date))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if let temperature = entry.roomTemperature {
                Text("\(temperature.formatted(.number.precision(.fractionLength(1))))°")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating")
                }
                .font(.caption.weight(.medium))
                .frame(height: 33)
            }
        }
    }

    private var powerButton: some View {
        Button(intent: ToggleClimatePowerIntent()) {
            WidgetControlLabel(
                title: "Power",
                symbol: "power",
                isOn: entry.state.ac.isOn,
                tint: .green,
                enabled: true
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var silenceButton: some View {
        if canToggleSilence {
            Button(intent: ToggleClimateSilenceIntent()) {
                WidgetControlLabel(
                    title: "Silence",
                    symbol: entry.state.ac.silence ? "speaker.slash.fill" : "speaker.wave.1.fill",
                    isOn: entry.state.ac.silence,
                    tint: .indigo,
                    enabled: true
                )
            }
            .buttonStyle(.plain)
        } else {
            WidgetControlLabel(
                title: "Silence",
                symbol: entry.state.ac.silence ? "speaker.slash.fill" : "speaker.wave.1.fill",
                isOn: entry.state.ac.silence,
                tint: .indigo,
                enabled: false
            )
        }
    }

    private var roomTemperatureTint: Color {
        guard let roomTemperature = entry.roomTemperature else { return .secondary }
        let delta = roomTemperature - Double(entry.state.ac.targetTemperature)
        let warmth = min(max((delta + 0.25) / 3.5, 0), 1)
        let cool = (red: 0.20, green: 0.49, blue: 0.76)
        let warm = (red: 0.86, green: 0.43, blue: 0.20)
        return Color(
            red: cool.red + (warm.red - cool.red) * warmth,
            green: cool.green + (warm.green - cool.green) * warmth,
            blue: cool.blue + (warm.blue - cool.blue) * warmth
        )
    }

    private func readingAge(since date: Date) -> String {
        let minutes = max(0, Int(entry.date.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr" }
        return "\(hours / 24) d"
    }

    @ViewBuilder
    private func temperatureButton<Intent: AppIntent>(
        symbol: String,
        enabled: Bool,
        intent: Intent
    ) -> some View {
        if enabled {
            Button(intent: intent) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 30)
                    .background(.primary.opacity(0.08), in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 30)
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                .opacity(0.28)
        }
    }
}

private struct WidgetControlLabel: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let tint: Color
    let enabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? tint : Color(.secondaryLabel))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(isOn ? Color.white : Color(.secondaryLabel))
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(isOn ? tint : Color.primary.opacity(0.07), in: .capsule)
        }
        .padding(.horizontal, 10)
        .frame(height: 31)
        .background(
            isOn ? tint.opacity(0.14) : Color.primary.opacity(0.045),
            in: .rect(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isOn ? tint.opacity(0.22) : Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .opacity(enabled ? 1 : 0.32)
    }
}

private struct WidgetGaugeArc: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY - 2)
        let radius = min(rect.width * 0.43, rect.height - 8)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(180 + 180 * min(max(progress, 0), 1)),
            clockwise: false
        )
        return path
    }
}

struct ClimateControlWidget: Widget {
    let kind = WidgetSharedStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClimateWidgetProvider()) { entry in
            ClimateWidgetView(entry: entry)
        }
        .configurationDisplayName("Climate Controls")
        .description("Control Climate and see the linked room temperature.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct ClimateWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClimateControlWidget()
    }
}
