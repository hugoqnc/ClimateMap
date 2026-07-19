import AppIntents
import WidgetKit

struct DecreaseClimateTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Decrease Climate Temperature"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await adjustTemperature(by: -1, command: "-")
        return .result()
    }
}

struct IncreaseClimateTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Increase Climate Temperature"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await adjustTemperature(by: 1, command: "+")
        return .result()
    }
}

struct ToggleClimateSilenceIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Climate Silence"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        var state = WidgetSharedStore.loadState()
        guard state.ac.isOn, !state.ac.eco else { return .result() }
        let previous = state.ac.silence
        state.ac.silence.toggle()
        WidgetSharedStore.saveState(state)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.widgetKind)

        do {
            let client = try WidgetClimateService.client()
            let remoteID = try await WidgetClimateService.remoteID(using: client)
            try await client.send("Silence", deviceID: remoteID)
        } catch {
            state.ac.silence = previous
            WidgetSharedStore.saveState(state)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.widgetKind)
            throw error
        }
        return .result()
    }
}

private func adjustTemperature(by amount: Int, command: String) async throws {
    var state = WidgetSharedStore.loadState()
    guard state.ac.isOn, !state.ac.eco else { return }
    let previous = state.ac.targetTemperature
    let desired = WidgetTemperatureRange.clamped(previous + amount)
    guard desired != previous else { return }
    state.ac.targetTemperature = desired
    WidgetSharedStore.saveState(state)
    WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.widgetKind)

    do {
        let client = try WidgetClimateService.client()
        let remoteID = try await WidgetClimateService.remoteID(using: client)
        try await client.send(command, deviceID: remoteID)
    } catch {
        state.ac.targetTemperature = previous
        WidgetSharedStore.saveState(state)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.widgetKind)
        throw error
    }
}
