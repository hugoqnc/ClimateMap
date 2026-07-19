import Foundation
import Observation
import UIKit
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

enum VentControlOperationStage: Equatable, Sendable {
    case returningOff
    case synchronizing
    case positioning
}

struct VentControlOperation: Equatable, Sendable {
    var stage: VentControlOperationStage
    var stageStartedAt: Date
    var targetPosition: Double?
    var automaticStartedAt: Date?
    var targetDate: Date?
    var movementStartedAt: Date? = nil
    var movementStartPosition: Double? = nil
    var requestedMode: OscillationMode? = nil
}

@MainActor
@Observable
final class HomeModel {
    private static let climateWidgetKind = "ClimateControlWidget"

    private let client: SwitchBotClient?
    private(set) var state: PersistedHomeState
    private var climateWidgetNeedsFinalReload = false
    private var restoredVentPreparationTask: Task<Void, Never>?
    private var ventOperationGeneration = 0

    var meters: [MeterReading] = []
    var climateRemote: SwitchBotInfraredRemote?
    var isRefreshing = false
    var isSendingCommand = false
    var commandActivity: String?
    var ventControlOperation: VentControlOperation?
    var requestedVentMode: OscillationMode?
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
        restorePersistedAutomaticPreparationIfNeeded()
    }

    func setLinkedMeter(_ id: String?) {
        state.linkedMeterID = id
        save(reloadClimateWidget: true)
    }

    func setPower(_ isOn: Bool) async {
        let retainedVentMode = requestedVentMode
            ?? ventControlOperation?.requestedMode
            ?? state.ac.oscillation
        restoredVentPreparationTask?.cancel()
        restoredVentPreparationTask = nil
        ventOperationGeneration += 1
        let operationGeneration = ventOperationGeneration
        ventControlOperation = nil
        requestedVentMode = nil

        let previous = state.ac
        state.ac.isOn = isOn
        if !isOn {
            state.ac.oscillation = retainedVentMode == .fixed ? .none : retainedVentMode
            state.ac.oscillationStartedAt = nil
        } else {
            state.ac.oscillation = retainedVentMode == .fixed ? .none : retainedVentMode
            state.ac.oscillationStartedAt = nil
        }
        save(reloadClimateWidget: true)
        commandActivity = isOn ? "Turning climate on…" : "Turning climate off…"
        let commandStartedAt = Date()
        let initializesAutomatic = isOn && state.ac.oscillation == .dynamic
        isSendingCommand = true
        if initializesAutomatic {
            ventControlOperation = VentControlOperation(
                stage: .synchronizing,
                stageStartedAt: commandStartedAt,
                targetPosition: nil,
                automaticStartedAt: commandStartedAt,
                targetDate: commandStartedAt.addingTimeInterval(
                    VentOscillationTiming.preparationDuration
                        + VentOscillationTiming.commandExecutionDelay
                ),
                requestedMode: .dynamic
            )
        }

        let succeeded = await send(isOn ? "On" : "Off", manageBusyState: false)
        guard operationGeneration == ventOperationGeneration else { return }
        guard succeeded else {
            state.ac = previous
            save(reloadClimateWidget: true)
            isSendingCommand = false
            ventControlOperation = nil
            commandActivity = nil
            return
        }

        if initializesAutomatic {
            state.ac.oscillationStartedAt = commandStartedAt
            save(reloadClimateWidget: true)
            isSendingCommand = false
            commandActivity = nil
            _ = await waitForAutomaticPreparation(
                startedAt: commandStartedAt,
                requestedMode: .dynamic,
                operationGeneration: operationGeneration
            )
            if operationGeneration == ventOperationGeneration {
                ventControlOperation = nil
            }
        } else {
            isSendingCommand = false
            ventControlOperation = nil
            commandActivity = nil
        }
    }

    private func restorePersistedAutomaticPreparationIfNeeded() {
        guard ventControlOperation == nil,
              !isSendingCommand,
              state.ac.isOn,
              state.ac.oscillation == .dynamic,
              let automaticStartedAt = state.ac.oscillationStartedAt
        else { return }

        let readyAt = automaticStartedAt.addingTimeInterval(
            VentOscillationTiming.preparationDuration
                + VentOscillationTiming.commandExecutionDelay
        )
        let remaining = readyAt.timeIntervalSinceNow
        guard remaining > 0 else { return }

        restoredVentPreparationTask?.cancel()
        ventControlOperation = VentControlOperation(
            stage: .synchronizing,
            stageStartedAt: Date(),
            targetPosition: nil,
            automaticStartedAt: automaticStartedAt,
            targetDate: readyAt,
            requestedMode: .dynamic
        )
        restoredVentPreparationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard let self,
                  self.state.ac.isOn,
                  self.state.ac.oscillation == .dynamic,
                  self.state.ac.oscillationStartedAt == automaticStartedAt
            else { return }
            self.ventControlOperation = nil
            self.restoredVentPreparationTask = nil
        }
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
        if enabled {
            state.ac.silence = false
        }
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
        let clamped = ClimateTemperatureRange.clamped(target)
        let startingTemperature = state.ac.targetTemperature
        let delta = clamped - startingTemperature
        guard delta != 0 else { return }
        state.ac.targetTemperature = clamped
        save(reloadClimateWidget: true)
        isSendingCommand = true
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
        isSendingCommand = true
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
        if mode == .fixed {
            await setFixedVentPosition(state.ac.fixedVentPosition ?? 0.5)
            return
        }
        guard state.ac.isOn, ventControlOperation == nil else { return }
        let needsAutomaticResynchronization = mode == .dynamic
            && state.ac.oscillation == .dynamic
            && state.ac.oscillationStartedAt == nil
        guard state.ac.oscillation != mode || needsAutomaticResynchronization else { return }

        ventOperationGeneration += 1
        let operationGeneration = ventOperationGeneration
        requestedVentMode = mode
        if needsAutomaticResynchronization {
            ventControlOperation = VentControlOperation(
                stage: .synchronizing,
                stageStartedAt: Date(),
                targetPosition: nil,
                automaticStartedAt: nil,
                targetDate: nil,
                requestedMode: .dynamic
            )
        }
        defer {
            if operationGeneration == ventOperationGeneration {
                ventControlOperation = nil
                requestedVentMode = nil
            }
        }

        if needsAutomaticResynchronization {
            guard let automaticStartedAt = await synchronizeAutomatic(
                targetPosition: nil,
                operationGeneration: operationGeneration
            ) else { return }
            _ = await waitForAutomaticPreparation(
                startedAt: automaticStartedAt,
                requestedMode: .dynamic,
                operationGeneration: operationGeneration
            )
            return
        }

        while state.ac.oscillation != mode {
            guard operationGeneration == ventOperationGeneration,
                  state.ac.isOn
            else { return }
            let nextMode = nextOscillationMode(after: state.ac.oscillation)
            if nextMode == .none {
                guard await advanceToOffAndWait(
                    targetPosition: nil,
                    requestedMode: mode,
                    operationGeneration: operationGeneration
                ) else { return }
            } else {
                let fixedPosition = nextMode == .fixed
                    ? ventPosition(
                        at: Date().addingTimeInterval(
                            VentOscillationTiming.commandExecutionDelay
                        )
                    )
                    : nil
                guard await advanceOscillation(
                    to: nextMode,
                    fixedPosition: fixedPosition,
                    operationGeneration: operationGeneration
                ) else { return }
            }
        }

        if mode == .dynamic, let automaticStartedAt = state.ac.oscillationStartedAt {
            _ = await waitForAutomaticPreparation(
                startedAt: automaticStartedAt,
                requestedMode: .dynamic,
                operationGeneration: operationGeneration
            )
        }
    }

    func setFixedVentPosition(_ position: Double) async {
        guard state.ac.isOn, ventControlOperation == nil else { return }
        let target = min(max(position, 0), 1)
        if state.ac.oscillation == .fixed,
           abs((state.ac.fixedVentPosition ?? 0.5) - target) < 0.005 {
            return
        }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Position climate vent")
        ventOperationGeneration += 1
        let operationGeneration = ventOperationGeneration
        requestedVentMode = .fixed
        ventControlOperation = VentControlOperation(
            stage: .synchronizing,
            stageStartedAt: Date(),
            targetPosition: target,
            automaticStartedAt: nil,
            targetDate: nil,
            requestedMode: .fixed
        )
        defer {
            if operationGeneration == ventOperationGeneration {
                ventControlOperation = nil
                requestedVentMode = nil
            }
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        guard let automaticStartedAt = await synchronizeAutomatic(
            targetPosition: target,
            operationGeneration: operationGeneration
        ), operationGeneration == ventOperationGeneration else { return }
        let targetDate = VentOscillationTiming.nextArrival(
            at: target,
            startedAt: automaticStartedAt,
            after: Date()
        )
        ventControlOperation = VentControlOperation(
            stage: .positioning,
            stageStartedAt: Date(),
            targetPosition: target,
            automaticStartedAt: automaticStartedAt,
            targetDate: targetDate,
            requestedMode: .fixed
        )

        let remaining = max(0, targetDate.timeIntervalSinceNow)
        do {
            try await Task.sleep(for: .seconds(remaining))
        } catch {
            return
        }

        guard operationGeneration == ventOperationGeneration,
              state.ac.isOn
        else { return }
        _ = await advanceOscillation(
            to: .fixed,
            fixedPosition: target,
            operationGeneration: operationGeneration
        )
    }

    func ventPosition(at date: Date) -> Double {
        guard state.ac.isOn else { return 0 }
        if ventControlOperation?.stage == .returningOff,
           let movementStartedAt = ventControlOperation?.movementStartedAt,
           let movementStartPosition = ventControlOperation?.movementStartPosition {
            return VentOscillationTiming.returningOffPosition(
                at: date,
                startedAt: movementStartedAt,
                from: movementStartPosition
            )
        }
        if let automaticStartedAt = ventControlOperation?.automaticStartedAt {
            return VentOscillationTiming.position(at: date, startedAt: automaticStartedAt)
        }
        switch state.ac.oscillation {
        case .none:
            return 0
        case .dynamic:
            guard let startedAt = state.ac.oscillationStartedAt else { return 1 }
            return VentOscillationTiming.position(at: date, startedAt: startedAt)
        case .fixed:
            return min(max(state.ac.fixedVentPosition ?? 0.5, 0), 1)
        }
    }

    private func synchronizeAutomatic(
        targetPosition: Double?,
        operationGeneration: Int
    ) async -> Date? {
        let requestedMode: OscillationMode = targetPosition == nil ? .dynamic : .fixed
        ventControlOperation = VentControlOperation(
            stage: .synchronizing,
            stageStartedAt: Date(),
            targetPosition: targetPosition,
            automaticStartedAt: nil,
            targetDate: nil,
            requestedMode: requestedMode
        )

        switch state.ac.oscillation {
        case .none:
            guard await advanceOscillation(
                to: .dynamic,
                operationGeneration: operationGeneration
            ) else { return nil }
        case .fixed:
            guard await advanceToOffAndWait(
                targetPosition: targetPosition,
                requestedMode: requestedMode,
                operationGeneration: operationGeneration
            ), await advanceOscillation(
                to: .dynamic,
                operationGeneration: operationGeneration
            )
            else { return nil }
        case .dynamic:
            if state.ac.oscillationStartedAt == nil {
                guard await advanceOscillation(
                    to: .fixed,
                    operationGeneration: operationGeneration
                ), await advanceToOffAndWait(
                    targetPosition: targetPosition,
                    requestedMode: requestedMode,
                    operationGeneration: operationGeneration
                ), await advanceOscillation(
                    to: .dynamic,
                    operationGeneration: operationGeneration
                )
                else { return nil }
            }
        }
        guard operationGeneration == ventOperationGeneration,
              state.ac.isOn
        else { return nil }
        return state.ac.oscillationStartedAt
    }

    private func advanceToOffAndWait(
        targetPosition: Double?,
        requestedMode: OscillationMode,
        operationGeneration: Int
    ) async -> Bool {
        let startPosition = ventPosition(at: Date())
        let movementStartedAt = Date()
        let readyAt = movementStartedAt.addingTimeInterval(
            VentOscillationTiming.returnToOffDuration
        )
        let completionAt = requestedMode == .none
            ? readyAt.addingTimeInterval(VentOscillationTiming.commandExecutionDelay)
            : readyAt
        ventControlOperation = VentControlOperation(
            stage: .returningOff,
            stageStartedAt: Date(),
            targetPosition: targetPosition,
            automaticStartedAt: nil,
            targetDate: completionAt,
            movementStartedAt: movementStartedAt,
            movementStartPosition: startPosition,
            requestedMode: requestedMode
        )
        guard await advanceOscillation(
            to: .none,
            operationGeneration: operationGeneration
        ) else { return false }

        let remaining = max(0, completionAt.timeIntervalSinceNow)
        guard remaining > 0 else { return true }
        do {
            try await Task.sleep(for: .seconds(remaining))
        } catch {
            return false
        }
        return operationGeneration == ventOperationGeneration
            && state.ac.isOn
    }

    private func waitForAutomaticPreparation(
        startedAt: Date,
        requestedMode: OscillationMode,
        operationGeneration: Int
    ) async -> Bool {
        let readyAt = startedAt.addingTimeInterval(
            VentOscillationTiming.preparationDuration
                + VentOscillationTiming.commandExecutionDelay
        )
        let remaining = max(0, readyAt.timeIntervalSinceNow)
        guard remaining > 0 else {
            return operationGeneration == ventOperationGeneration && state.ac.isOn
        }

        ventControlOperation = VentControlOperation(
            stage: .synchronizing,
            stageStartedAt: Date(),
            targetPosition: nil,
            automaticStartedAt: startedAt,
            targetDate: readyAt,
            requestedMode: requestedMode
        )
        do {
            try await Task.sleep(for: .seconds(remaining))
        } catch {
            return false
        }
        return operationGeneration == ventOperationGeneration
            && state.ac.isOn
    }

    private func advanceOscillation(
        to mode: OscillationMode,
        fixedPosition: Double? = nil,
        operationGeneration: Int
    ) async -> Bool {
        let commandStartedAt = Date()
        guard await send("Oscillation", manageBusyState: false) else { return false }

        // The API request is intentionally sent above without delay. Only the
        // represented physical response waits for the calibrated IR latency.
        let executionAt = commandStartedAt.addingTimeInterval(
            VentOscillationTiming.commandExecutionDelay
        )
        let remaining = max(0, executionAt.timeIntervalSinceNow)
        if remaining > 0 {
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return false
            }
        }
        guard operationGeneration == ventOperationGeneration,
              state.ac.isOn
        else { return false }
        state.ac.oscillation = mode
        switch mode {
        case .none:
            state.ac.oscillationStartedAt = nil
        case .dynamic:
            state.ac.oscillationStartedAt = commandStartedAt
        case .fixed:
            state.ac.oscillationStartedAt = nil
            if let fixedPosition {
                state.ac.fixedVentPosition = min(max(fixedPosition, 0), 1)
            }
        }
        save(reloadClimateWidget: true)
        return true
    }

    private func nextOscillationMode(after mode: OscillationMode) -> OscillationMode {
        let nextRawValue = (mode.rawValue + 1) % OscillationMode.allCases.count
        return OscillationMode(rawValue: nextRawValue) ?? .none
    }

    private func send(_ command: String, manageBusyState: Bool = true) async -> Bool {
        guard let client, let climateRemote else {
            errorMessage = "Climate remote is not available."
            return false
        }
        if manageBusyState { isSendingCommand = true }
        do {
            try await client.sendCustomCommand(command, deviceID: climateRemote.deviceId)
            if manageBusyState { isSendingCommand = false }
            errorMessage = nil
            return true
        } catch {
            if manageBusyState { isSendingCommand = false }
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
