import Foundation

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
        case .none: "Off"
        case .dynamic: "Dynamic"
        case .fixed: "Fixed"
        }
    }
}

struct ACState: Codable, Equatable, Sendable {
    var isOn = true
    var targetTemperature = 24
    var fanLevel: FanLevel = .high
    var silence = false
    var eco = false
    var oscillation: OscillationMode = .none
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
              let decoded = try? JSONDecoder().decode(PersistedHomeState.self, from: data)
        else {
            guard explicitDefaults == nil,
                  let legacyData = UserDefaults.standard.data(forKey: key),
                  let legacyState = try? JSONDecoder().decode(PersistedHomeState.self, from: legacyData)
            else { return PersistedHomeState() }
            save(legacyState, defaults: defaults)
            return legacyState
        }
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
