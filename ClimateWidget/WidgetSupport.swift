import CryptoKit
import Foundation

enum WidgetTemperatureRange {
    static let minimum = 18
    static let maximum = 30

    static func clamped(_ temperature: Int) -> Int {
        min(max(temperature, minimum), maximum)
    }
}

enum WidgetFanLevel: Int, Codable, Sendable {
    case low, medium, high, auto
}

enum WidgetOscillationMode: Int, Codable, Sendable {
    case none, dynamic, fixed
}

struct WidgetACState: Codable, Sendable {
    var isOn = true
    var targetTemperature = 24
    var fanLevel: WidgetFanLevel = .high
    var silence = false
    var eco = false
    var oscillation: WidgetOscillationMode = .none
    var fixedVentPosition: Double?
    var oscillationStartedAt: Date?
}

struct WidgetPlanPoint: Codable, Sendable {
    var x: Double
    var y: Double
}

struct WidgetHomeState: Codable, Sendable {
    var positions: [String: WidgetPlanPoint] = [:]
    var ac = WidgetACState()
    var linkedMeterID: String?
    var homePowerSwitchID: String?
    var homePowerSwitchName: String?
}

struct WidgetClimateCache: Codable, Sendable {
    let roomTemperature: Double
    let updatedAt: Date
    let remoteID: String
    let meterID: String
}

enum WidgetSharedStore {
    static let widgetKind = "ClimateControlWidget"
    private static let appGroup = "group.com.queinnec.SmartHome"
    private static let stateKey = "personal-smart-home-state-v1"
    private static let cacheKey = "climate-widget-cache-v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func loadState() -> WidgetHomeState {
        guard let data = defaults.data(forKey: stateKey),
              var state = try? JSONDecoder().decode(WidgetHomeState.self, from: data)
        else { return WidgetHomeState() }
        state.ac.targetTemperature = WidgetTemperatureRange.clamped(
            state.ac.targetTemperature
        )
        return state
    }

    static func saveState(_ state: WidgetHomeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    static func loadCache() -> WidgetClimateCache? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(WidgetClimateCache.self, from: data)
    }

    static func saveCache(_ cache: WidgetClimateCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}

struct WidgetCredentials: Sendable {
    let token: String
    let secret: String

    static func bundled() throws -> WidgetCredentials {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "SwitchBotToken") as? String,
              let secret = Bundle.main.object(forInfoDictionaryKey: "SwitchBotSecret") as? String,
              !token.isEmpty, !secret.isEmpty,
              !token.contains("$("), !secret.contains("$(")
        else { throw WidgetAPIError.missingCredentials }
        return WidgetCredentials(token: token, secret: secret)
    }
}

struct WidgetDevice: Decodable, Sendable {
    let deviceId: String
    let deviceName: String
    let deviceType: String

    var isMeter: Bool { deviceType.localizedCaseInsensitiveContains("meter") }
}

struct WidgetRemote: Decodable, Sendable {
    let deviceId: String
    let remoteType: String
}

struct WidgetDeviceList: Decodable, Sendable {
    let deviceList: [WidgetDevice]
    let infraredRemoteList: [WidgetRemote]
}

struct WidgetMeterStatus: Decodable, Sendable {
    let temperature: Double
    let humidity: Int

    var isPlausible: Bool {
        temperature.isFinite && temperature != 0
            && (-40.0...80.0).contains(temperature)
            && (1...100).contains(humidity)
    }
}

private struct WidgetEnvelope<Body: Decodable & Sendable>: Decodable, Sendable {
    let statusCode: Int
    let body: Body
    let message: String
}

private struct WidgetCommandEnvelope: Decodable, Sendable {
    let statusCode: Int
    let message: String
}

private struct WidgetCommand: Encodable, Sendable {
    let command: String
    let parameter = "default"
    let commandType = "customize"
}

enum WidgetAPIError: LocalizedError, Sendable {
    case missingCredentials
    case invalidResponse
    case remoteUnavailable
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "SwitchBot credentials are unavailable to the widget."
        case .invalidResponse: "SwitchBot returned an invalid response."
        case .remoteUnavailable: "The Climate remote is unavailable."
        case let .api(message): message
        }
    }
}

actor WidgetSwitchBotClient {
    private let credentials: WidgetCredentials
    private let session: URLSession
    private let baseURL = URL(string: "https://api.switch-bot.com/v1.1")!

    init(credentials: WidgetCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func devices() async throws -> WidgetDeviceList {
        try await get(path: "devices", as: WidgetDeviceList.self)
    }

    func meterStatus(deviceID: String) async throws -> WidgetMeterStatus {
        try await get(path: "devices/\(deviceID)/status", as: WidgetMeterStatus.self)
    }

    func send(_ command: String, deviceID: String) async throws {
        var request = signedRequest(path: "devices/\(deviceID)/commands", method: "POST")
        request.httpBody = try JSONEncoder().encode(WidgetCommand(command: command))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(WidgetCommandEnvelope.self, from: data)
        else { throw WidgetAPIError.invalidResponse }
        guard envelope.statusCode == 100 else { throw WidgetAPIError.api(envelope.message) }
    }

    private func get<Body: Decodable & Sendable>(path: String, as type: Body.Type) async throws -> Body {
        let (data, response) = try await session.data(for: signedRequest(path: path, method: "GET"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(WidgetEnvelope<Body>.self, from: data)
        else { throw WidgetAPIError.invalidResponse }
        guard envelope.statusCode == 100 else { throw WidgetAPIError.api(envelope.message) }
        return envelope.body
    }

    private func signedRequest(path: String, method: String) -> URLRequest {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let nonce = UUID().uuidString
        let payload = Data("\(credentials.token)\(timestamp)\(nonce)".utf8)
        let key = SymmetricKey(data: Data(credentials.secret.utf8))
        let authentication = HMAC<SHA256>.authenticationCode(for: payload, using: key)

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue(credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue(Data(authentication).base64EncodedString(), forHTTPHeaderField: "sign")
        request.setValue(nonce, forHTTPHeaderField: "nonce")
        request.setValue(timestamp, forHTTPHeaderField: "t")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

enum WidgetClimateService {
    static func client() throws -> WidgetSwitchBotClient {
        WidgetSwitchBotClient(credentials: try .bundled())
    }

    static func remoteID(using client: WidgetSwitchBotClient) async throws -> String {
        if let cached = WidgetSharedStore.loadCache()?.remoteID { return cached }
        let devices = try await client.devices()
        guard let remote = devices.infraredRemoteList.first(where: {
            $0.remoteType.localizedCaseInsensitiveCompare("Others") == .orderedSame
        }) else { throw WidgetAPIError.remoteUnavailable }
        return remote.deviceId
    }
}
