import AppIntents
import WidgetKit

struct ToggleClimatePowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Climate Power"
    static let description = IntentDescription("Turns Climate on or off.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        var state = WidgetSharedStore.loadState()
        let previous = state.ac.isOn
        let desired = !previous
        state.ac.isOn = desired
        WidgetSharedStore.saveState(state)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.widgetKind)

        do {
            let client = try WidgetClimateService.client()
            let remoteID = try await WidgetClimateService.remoteID(using: client)
            try await client.send(desired ? "On" : "Off", deviceID: remoteID)
        } catch {
            state.ac.isOn = previous
            WidgetSharedStore.saveState(state)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.widgetKind)
            throw error
        }
        return .result()
    }
}

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
    let desired = min(max(previous + amount, 16), 30)
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
