import Foundation
import Observation
import WidgetKit

struct MeterReading: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let temperature: Double
    let humidity: Int
    let battery: Int
    let isAvailable: Bool

    init(device: SwitchBotDevice, status: SwitchBotMeterStatus?) {
        id = device.deviceId
        name = device.deviceName
        if let status,
           status.temperature.isFinite,
           status.temperature != 0,
           (-40.0...80.0).contains(status.temperature),
           (1...100).contains(status.humidity) {
            temperature = status.temperature
            humidity = status.humidity
            battery = status.battery
            isAvailable = true
        } else {
            temperature = 0
            humidity = 0
            battery = 0
            isAvailable = false
        }
    }
}

@MainActor
@Observable
final class HomeModel {
    private static let climateWidgetKind = "ClimateControlWidget"

    private let client: SwitchBotClient?
    private(set) var state: PersistedHomeState
    private var climateWidgetNeedsFinalReload = false

    var meters: [MeterReading] = []
    var climateRemote: SwitchBotInfraredRemote?
    var isRefreshing = false
    var isSendingCommand = false
    var commandActivity: String?
    var errorMessage: String?
    var lastUpdated: Date?
    var lastRefreshAttempt: Date?

    init() {
        state = HomeStatePersistence.load()
        do {
            client = SwitchBotClient(credentials: try .bundled())
        } catch {
            client = nil
            errorMessage = error.localizedDescription
        }
    }

    var linkedMeter: MeterReading? {
        meters.first { $0.id == state.linkedMeterID }
    }

    var hasCompleteMeterData: Bool {
        !meters.isEmpty && meters.allSatisfy(\.isAvailable)
    }

    var readingsAreStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > 120
    }

    func refreshIfNeeded(maxAge: TimeInterval = 60) async {
        guard !isRefreshing else { return }
        let mostRecentActivity = [lastUpdated, lastRefreshAttempt]
            .compactMap { $0 }
            .max()
        if let mostRecentActivity, Date().timeIntervalSince(mostRecentActivity) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        lastRefreshAttempt = Date()
        defer { isRefreshing = false }
        do {
            let deviceList = try await client.devices()
            let meterDevices = deviceList.deviceList.filter(\.isMeter)
            let readings = await withTaskGroup(of: MeterReading.self) { group in
                for device in meterDevices {
                    group.addTask {
                        let status = try? await client.meterStatus(deviceID: device.deviceId)
                        return MeterReading(device: device, status: status)
                    }
                }
                var values: [MeterReading] = []
                for await reading in group {
                    values.append(reading)
                }
                return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            meters = readings
            climateRemote = deviceList.infraredRemoteList.first {
                $0.remoteType.localizedCaseInsensitiveCompare("Others") == .orderedSame
            }
            ensureInitialPlacement()
            if !readings.isEmpty, readings.allSatisfy(\.isAvailable) {
                lastUpdated = Date()
            }
            updateWidgetCache(from: readings)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func position(for deviceID: String) -> PlanPoint? {
        state.positions[deviceID]
    }

    func setPosition(_ position: PlanPoint, for deviceID: String, persist: Bool) {
        state.positions[deviceID] = PlanPoint(
            x: min(max(position.x, 0.035), 0.943),
            y: min(max(position.y, 0.02), 0.98)
        )
        if persist { save() }
    }

    func persistPositions() {
        save()
    }

    func reloadPersistedState() {
        state = HomeStatePersistence.load()
    }

    func setLinkedMeter(_ id: String?) {
        state.linkedMeterID = id
        save(reloadClimateWidget: true)
    }

    func setPower(_ isOn: Bool) async {
        let previous = state.ac.isOn
        state.ac.isOn = isOn
        save(reloadClimateWidget: true)
        commandActivity = isOn ? "Turning climate on…" : "Turning climate off…"
        guard await send(isOn ? "On" : "Off") else {
            state.ac.isOn = previous
            save(reloadClimateWidget: true)
            commandActivity = nil
            return
        }
        commandActivity = nil
    }

    func setSilence(_ enabled: Bool) async {
        let previous = state.ac.silence
        state.ac.silence = enabled
        save(reloadClimateWidget: true)
        commandActivity = enabled ? "Enabling silence…" : "Disabling silence…"
        guard await send("Silence") else {
            state.ac.silence = previous
            save(reloadClimateWidget: true)
            commandActivity = nil
            return
        }
        commandActivity = nil
    }

    func setEco(_ enabled: Bool) async {
        let previous = state.ac.eco
        let previousSilence = state.ac.silence
        state.ac.eco = enabled
        if enabled { state.ac.silence = false }
        save(reloadClimateWidget: true)
        commandActivity = enabled ? "Enabling Eco…" : "Disabling Eco…"
        guard await send("Eco") else {
            state.ac.eco = previous
            state.ac.silence = previousSilence
            save(reloadClimateWidget: true)
            commandActivity = nil
            return
        }
        commandActivity = nil
    }

    func setTargetTemperature(_ target: Int) async {
        let clamped = min(max(target, 16), 30)
        let startingTemperature = state.ac.targetTemperature
        let delta = clamped - startingTemperature
        guard delta != 0 else { return }
        state.ac.targetTemperature = clamped
        save(reloadClimateWidget: true)
        commandActivity = "Setting \(clamped)°…"
        let command = delta > 0 ? "+" : "-"
        var completedSteps = 0
        for _ in 0..<abs(delta) {
            guard await send(command, manageBusyState: false) else { break }
            completedSteps += 1
        }
        if completedSteps != abs(delta) {
            state.ac.targetTemperature = startingTemperature + completedSteps * delta.signum()
            save(reloadClimateWidget: true)
        }
        isSendingCommand = false
        commandActivity = nil
    }

    func setFanLevel(_ level: FanLevel) async {
        let startingLevel = state.ac.fanLevel
        let steps = (level.rawValue - startingLevel.rawValue + FanLevel.allCases.count) % FanLevel.allCases.count
        guard steps > 0 else { return }
        state.ac.fanLevel = level
        save(reloadClimateWidget: true)
        commandActivity = "Changing ventilation…"
        var completedSteps = 0
        for _ in 0..<steps {
            guard await send("Souffle", manageBusyState: false) else { break }
            completedSteps += 1
        }
        if completedSteps != steps {
            let actualRawValue = (startingLevel.rawValue + completedSteps) % FanLevel.allCases.count
            state.ac.fanLevel = FanLevel(rawValue: actualRawValue) ?? startingLevel
            save(reloadClimateWidget: true)
        }
        isSendingCommand = false
        commandActivity = nil
    }

    func setOscillation(_ mode: OscillationMode) async {
        let startingMode = state.ac.oscillation
        let steps = (mode.rawValue - startingMode.rawValue + OscillationMode.allCases.count) % OscillationMode.allCases.count
        guard steps > 0 else { return }
        state.ac.oscillation = mode
        save(reloadClimateWidget: true)
        commandActivity = "Changing oscillation…"
        var completedSteps = 0
        for _ in 0..<steps {
            guard await send("Oscillation", manageBusyState: false) else { break }
            completedSteps += 1
        }
        if completedSteps != steps {
            let actualRawValue = (startingMode.rawValue + completedSteps) % OscillationMode.allCases.count
            state.ac.oscillation = OscillationMode(rawValue: actualRawValue) ?? startingMode
            save(reloadClimateWidget: true)
        }
        isSendingCommand = false
        commandActivity = nil
    }

    private func send(_ command: String, manageBusyState: Bool = true) async -> Bool {
        guard let client, let climateRemote else {
            errorMessage = "Climate remote is not available."
            return false
        }
        isSendingCommand = true
        do {
            try await client.sendCustomCommand(command, deviceID: climateRemote.deviceId)
            if manageBusyState { isSendingCommand = false }
            errorMessage = nil
            return true
        } catch {
            isSendingCommand = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func ensureInitialPlacement() {
        var changed = false
        for (index, meter) in meters.enumerated() where state.positions[meter.id] == nil {
            state.positions[meter.id] = ApartmentFloorPlan.suggestedMeterPositions[
                min(index, ApartmentFloorPlan.suggestedMeterPositions.count - 1)
            ]
            changed = true
        }
        if state.linkedMeterID == nil, let firstMeter = meters.first {
            state.linkedMeterID = firstMeter.id
            changed = true
        }
        if changed { save() }
    }

    private func updateWidgetCache(from readings: [MeterReading]) {
        guard let climateRemote,
              let linkedMeterID = state.linkedMeterID,
              let linkedMeter = readings.first(where: { $0.id == linkedMeterID && $0.isAvailable })
        else { return }
        WidgetClimateCacheStore.save(WidgetClimateCache(
            roomTemperature: linkedMeter.temperature,
            updatedAt: Date(),
            remoteID: climateRemote.deviceId,
            meterID: linkedMeter.id
        ))
        WidgetCenter.shared.reloadTimelines(ofKind: Self.climateWidgetKind)
    }

    func flushPendingClimateWidgetUpdate() {
        guard climateWidgetNeedsFinalReload else { return }
        climateWidgetNeedsFinalReload = false
        WidgetCenter.shared.reloadTimelines(ofKind: Self.climateWidgetKind)
    }

    private func save(reloadClimateWidget: Bool = false) {
        HomeStatePersistence.save(state)
        guard reloadClimateWidget else { return }
        climateWidgetNeedsFinalReload = true
        WidgetCenter.shared.reloadTimelines(ofKind: Self.climateWidgetKind)
    }
}
