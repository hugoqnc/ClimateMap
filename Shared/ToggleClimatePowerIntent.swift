import AppIntents
import CryptoKit
import Foundation
@preconcurrency import HomeKit
import WidgetKit

struct ToggleClimatePowerIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Climate Power"
    static let description = IntentDescription("Turns Climate on or off.")
    static let openAppWhenRun = false
    static let supportedModes: IntentModes = [.foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        var state = PowerIntentStore.loadState()
        let previousAC = state.ac
        let commandStartedAt = Date()

        do {
            let desiredPower: Bool
            if let switchID = state.homePowerSwitchID {
                let homeSession = await MainAppHomePowerSession()
                let currentPower = try await homeSession.powerState(switchID: switchID)
                desiredPower = !currentPower
                update(&state, forPower: desiredPower, commandStartedAt: commandStartedAt)
                PowerIntentStore.saveState(state)
                WidgetCenter.shared.reloadTimelines(ofKind: PowerIntentStore.widgetKind)
                try await homeSession.setPower(desiredPower, switchID: switchID)
            } else {
                desiredPower = !state.ac.isOn
                update(&state, forPower: desiredPower, commandStartedAt: commandStartedAt)
                PowerIntentStore.saveState(state)
                WidgetCenter.shared.reloadTimelines(ofKind: PowerIntentStore.widgetKind)
                try await PowerIntentSwitchBotClient().setPower(desiredPower)
            }

            WidgetCenter.shared.reloadTimelines(ofKind: PowerIntentStore.widgetKind)
        } catch {
            state.ac = previousAC
            PowerIntentStore.saveState(state)
            WidgetCenter.shared.reloadTimelines(ofKind: PowerIntentStore.widgetKind)
            throw error
        }
        return .result()
    }

    private func update(
        _ state: inout PowerIntentHomeState,
        forPower isOn: Bool,
        commandStartedAt: Date
    ) {
        state.ac.isOn = isOn
        if state.ac.oscillation == 2 {
            state.ac.oscillation = 0
        }
        state.ac.oscillationStartedAt = isOn && state.ac.oscillation == 1
            ? commandStartedAt
            : nil
    }
}

private struct PowerIntentPoint: Codable, Sendable {
    var x: Double
    var y: Double
}

private struct PowerIntentACState: Codable, Sendable {
    var isOn = true
    var targetTemperature = 24
    var fanLevel = 2
    var silence = false
    var eco = false
    var oscillation = 0
    var fixedVentPosition: Double?
    var oscillationStartedAt: Date?
}

private struct PowerIntentHomeState: Codable, Sendable {
    var positions: [String: PowerIntentPoint] = [:]
    var ac = PowerIntentACState()
    var linkedMeterID: String?
    var homePowerSwitchID: String?
    var homePowerSwitchName: String?
}

private enum PowerIntentStore {
    static let widgetKind = "ClimateControlWidget"
    private static let appGroup = "group.com.queinnec.SmartHome"
    private static let stateKey = "personal-smart-home-state-v1"
    private static let cacheKey = "climate-widget-cache-v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func loadState() -> PowerIntentHomeState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(PowerIntentHomeState.self, from: data)
        else { return PowerIntentHomeState() }
        return state
    }

    static func saveState(_ state: PowerIntentHomeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    static func cachedRemoteID() -> String? {
        guard let data = defaults.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(PowerIntentCache.self, from: data)
        else { return nil }
        return cache.remoteID
    }
}

private struct PowerIntentCache: Decodable, Sendable {
    let remoteID: String
}

private enum PowerIntentError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case remoteUnavailable
    case homeUnauthorized
    case homeSwitchUnavailable
    case unreadableHomeValue
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "SwitchBot credentials are unavailable."
        case .invalidResponse: "The power service returned an invalid response."
        case .remoteUnavailable: "The Climate remote is unavailable."
        case .homeUnauthorized: "ClimateMap does not have access to Apple Home."
        case .homeSwitchUnavailable: "The selected Apple Home switch is unavailable."
        case .unreadableHomeValue: "Apple Home did not return the switch state."
        case let .api(message): message
        }
    }
}

@MainActor
private final class MainAppHomePowerSession: NSObject,
    @preconcurrency HMHomeManagerDelegate {
    private var manager: HMHomeManager?
    private var homesAreReady = false
    private var homesWaiters: [CheckedContinuation<Void, Never>] = []

    func powerState(switchID: String) async throws -> Bool {
        let characteristic = try await powerCharacteristic(switchID: switchID)
        try await read(characteristic)
        guard let value = characteristic.value as? NSNumber else {
            throw PowerIntentError.unreadableHomeValue
        }
        return value.boolValue
    }

    func setPower(_ isOn: Bool, switchID: String) async throws {
        let characteristic = try await powerCharacteristic(switchID: switchID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(isOn) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homesAreReady = true
        let waiters = homesWaiters
        homesWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func powerCharacteristic(switchID: String) async throws -> HMCharacteristic {
        let manager = await preparedManager()
        guard manager.authorizationStatus.contains(.authorized) else {
            throw PowerIntentError.homeUnauthorized
        }
        for home in manager.homes {
            for accessory in home.accessories {
                for service in accessory.services
                where service.serviceType == HMServiceTypeSwitch
                    || service.serviceType == HMServiceTypeOutlet {
                    if let characteristic = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypePowerState
                            && $0.uniqueIdentifier.uuidString == switchID
                    }) {
                        return characteristic
                    }
                }
            }
        }
        throw PowerIntentError.homeSwitchUnavailable
    }

    private func preparedManager() async -> HMHomeManager {
        if let manager, homesAreReady { return manager }
        let manager: HMHomeManager
        if let existing = self.manager {
            manager = existing
        } else {
            manager = HMHomeManager()
            manager.delegate = self
            self.manager = manager
        }
        if !homesAreReady {
            await withCheckedContinuation { continuation in
                homesWaiters.append(continuation)
            }
        }
        return manager
    }

    private func read(_ characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.readValue { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private struct PowerIntentCredentials: Sendable {
    let token: String
    let secret: String

    static func bundled() throws -> PowerIntentCredentials {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "SwitchBotToken") as? String,
              let secret = Bundle.main.object(forInfoDictionaryKey: "SwitchBotSecret") as? String,
              !token.isEmpty, !secret.isEmpty,
              !token.contains("$("), !secret.contains("$(")
        else { throw PowerIntentError.missingCredentials }
        return PowerIntentCredentials(token: token, secret: secret)
    }
}

private struct PowerIntentDeviceList: Decodable, Sendable {
    let infraredRemoteList: [PowerIntentRemote]
}

private struct PowerIntentRemote: Decodable, Sendable {
    let deviceId: String
    let remoteType: String
}

private struct PowerIntentEnvelope<Body: Decodable & Sendable>: Decodable, Sendable {
    let statusCode: Int
    let body: Body
    let message: String
}

private struct PowerIntentCommandEnvelope: Decodable, Sendable {
    let statusCode: Int
    let message: String
}

private struct PowerIntentCommand: Encodable, Sendable {
    let command: String
    let parameter = "default"
    let commandType = "customize"
}

private struct PowerIntentSwitchBotClient: Sendable {
    private let baseURL = URL(string: "https://api.switch-bot.com/v1.1")!

    func setPower(_ isOn: Bool) async throws {
        let credentials = try PowerIntentCredentials.bundled()
        let remoteID: String
        if let cachedRemoteID = PowerIntentStore.cachedRemoteID() {
            remoteID = cachedRemoteID
        } else {
            remoteID = try await discoverRemoteID(credentials: credentials)
        }
        var request = signedRequest(
            path: "devices/\(remoteID)/commands",
            method: "POST",
            credentials: credentials
        )
        request.httpBody = try JSONEncoder().encode(
            PowerIntentCommand(command: isOn ? "On" : "Off")
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(PowerIntentCommandEnvelope.self, from: data)
        else { throw PowerIntentError.invalidResponse }
        guard envelope.statusCode == 100 else {
            throw PowerIntentError.api(envelope.message)
        }
    }

    private func discoverRemoteID(credentials: PowerIntentCredentials) async throws -> String {
        let request = signedRequest(path: "devices", method: "GET", credentials: credentials)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(
                PowerIntentEnvelope<PowerIntentDeviceList>.self,
                from: data
              )
        else { throw PowerIntentError.invalidResponse }
        guard envelope.statusCode == 100 else {
            throw PowerIntentError.api(envelope.message)
        }
        guard let remote = envelope.body.infraredRemoteList.first(where: {
            $0.remoteType.localizedCaseInsensitiveCompare("Others") == .orderedSame
        }) else { throw PowerIntentError.remoteUnavailable }
        return remote.deviceId
    }

    private func signedRequest(
        path: String,
        method: String,
        credentials: PowerIntentCredentials
    ) -> URLRequest {
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
