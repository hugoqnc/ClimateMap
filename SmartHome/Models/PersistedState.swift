import Foundation

enum ClimateTemperatureRange {
    static let minimum = 18
    static let maximum = 30

    static func clamped(_ temperature: Int) -> Int {
        min(max(temperature, minimum), maximum)
    }
}

enum FanLevel: Int, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case auto

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .auto: "Auto"
        }
    }

    var symbol: String {
        switch self {
        case .low: "wind"
        case .medium: "wind"
        case .high: "tornado"
        case .auto: "a.circle.fill"
        }
    }
}

enum OscillationMode: Int, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case dynamic
    case fixed

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: "Closed"
        case .dynamic: "Auto"
        case .fixed: "Fixed"
        }
    }
}

enum VentOscillationTiming {
    // Average time between sending an infrared command and the appliance
    // physically starting it. Keep request scheduling immediate; this offset
    // is only used by the modeled appliance state and its animations.
    static let commandExecutionDelay: TimeInterval = 1.0
    static let returnToOffDuration: TimeInterval = 6
    static let preparationDuration: TimeInterval = 13
    static let oneWayTravelDuration: TimeInterval = 7.5
    static let fullCycleDuration: TimeInterval = oneWayTravelDuration * 2

    static func position(at date: Date, startedAt: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(startedAt) - commandExecutionDelay)
        guard elapsed >= preparationDuration else {
            return initializationPosition(at: elapsed)
        }
        let phase = (elapsed - preparationDuration)
            .truncatingRemainder(dividingBy: fullCycleDuration)
        if phase <= oneWayTravelDuration {
            return 1 - phase / oneWayTravelDuration
        }
        return (phase - oneWayTravelDuration) / oneWayTravelDuration
    }

    // The appliance performs two vent-widths of motion over its 13-second
    // initialization: down -> up -> midpoint -> up. Allocating time by travel
    // distance keeps the represented vent speed constant throughout.
    static func initializationPosition(at elapsed: TimeInterval) -> Double {
        let clampedElapsed = min(max(elapsed, 0), preparationDuration)
        let fullSweepDuration = preparationDuration / 2
        let halfSweepDuration = preparationDuration / 4

        if clampedElapsed <= fullSweepDuration {
            return clampedElapsed / fullSweepDuration
        }
        if clampedElapsed <= fullSweepDuration + halfSweepDuration {
            let phase = (clampedElapsed - fullSweepDuration) / halfSweepDuration
            return 1 - phase * 0.5
        }
        let phase = (clampedElapsed - fullSweepDuration - halfSweepDuration)
            / halfSweepDuration
        return 0.5 + phase * 0.5
    }

    static func returningOffPosition(
        at date: Date,
        startedAt: Date,
        from startPosition: Double
    ) -> Double {
        let elapsed = max(0, date.timeIntervalSince(startedAt) - commandExecutionDelay)
        let progress = min(elapsed / returnToOffDuration, 1)
        return min(max(startPosition, 0), 1) * (1 - progress)
    }

    static func nextArrival(
        at targetPosition: Double,
        startedAt: Date,
        after date: Date
    ) -> Date {
        let target = min(max(targetPosition, 0), 1)
        let cycleStart = startedAt.addingTimeInterval(preparationDuration)
        let downwardOffset = (1 - target) * oneWayTravelDuration
        let upwardOffset = oneWayTravelDuration + target * oneWayTravelDuration
        let minimumLead: TimeInterval = 0.12

        if cycleStart.addingTimeInterval(downwardOffset).timeIntervalSince(date) > minimumLead {
            return cycleStart.addingTimeInterval(downwardOffset)
        }

        let elapsedCycles = max(0, date.timeIntervalSince(cycleStart) / fullCycleDuration)
        let baseCycle = Int(floor(elapsedCycles))
        for cycle in baseCycle...(baseCycle + 2) {
            let cycleOffset = Double(cycle) * fullCycleDuration
            for offset in [downwardOffset, upwardOffset] {
                let candidate = cycleStart.addingTimeInterval(cycleOffset + offset)
                if candidate.timeIntervalSince(date) > minimumLead {
                    return candidate
                }
            }
        }
        return date.addingTimeInterval(fullCycleDuration)
    }
}

struct ACState: Codable, Equatable, Sendable {
    var isOn = true
    var targetTemperature = 24
    var fanLevel: FanLevel = .high
    var silence = false
    var eco = false
    var oscillation: OscillationMode = .none
    var fixedVentPosition: Double?
    var oscillationStartedAt: Date?
}

struct PersistedHomeState: Codable, Sendable {
    var positions: [String: PlanPoint] = [:]
    var ac = ACState()
    var linkedMeterID: String?
}

enum HomeStatePersistence {
    static let appGroupIdentifier = "group.com.queinnec.SmartHome"
    static let key = "personal-smart-home-state-v1"

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func load(defaults explicitDefaults: UserDefaults? = nil) -> PersistedHomeState {
        let defaults = explicitDefaults ?? sharedDefaults
        guard let data = defaults.data(forKey: key),
              var decoded = try? JSONDecoder().decode(PersistedHomeState.self, from: data)
        else {
            guard explicitDefaults == nil,
                  let legacyData = UserDefaults.standard.data(forKey: key),
                  var legacyState = try? JSONDecoder().decode(PersistedHomeState.self, from: legacyData)
            else { return PersistedHomeState() }
            legacyState.ac.targetTemperature = ClimateTemperatureRange.clamped(
                legacyState.ac.targetTemperature
            )
            save(legacyState, defaults: defaults)
            return legacyState
        }
        decoded.ac.targetTemperature = ClimateTemperatureRange.clamped(
            decoded.ac.targetTemperature
        )
        return decoded
    }

    static func save(_ state: PersistedHomeState, defaults explicitDefaults: UserDefaults? = nil) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let defaults = explicitDefaults ?? sharedDefaults
        defaults.set(data, forKey: key)
    }
}

struct WidgetClimateCache: Codable, Sendable {
    let roomTemperature: Double
    let updatedAt: Date
    let remoteID: String
    let meterID: String
}

enum WidgetClimateCacheStore {
    static let key = "climate-widget-cache-v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: HomeStatePersistence.appGroupIdentifier) ?? .standard
    }

    static func load() -> WidgetClimateCache? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetClimateCache.self, from: data)
    }

    static func save(_ cache: WidgetClimateCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: key)
    }
}
