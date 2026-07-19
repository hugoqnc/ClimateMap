import Foundation
@preconcurrency import HomeKit

enum AppleHomeAccessState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var isAuthorized: Bool { self == .authorized }

    var title: String {
        switch self {
        case .notDetermined: "Connecting to Apple Home"
        case .authorized: "Apple Home connected"
        case .denied: "Apple Home access denied"
        case .restricted: "Apple Home access restricted"
        }
    }

    var symbol: String {
        switch self {
        case .notDetermined, .authorized: "homekit"
        case .denied, .restricted: "house.badge.exclamationmark"
        }
    }
}

struct AppleHomePowerSwitch: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let roomName: String?
    let isOn: Bool
    let isReachable: Bool
}

enum AppleHomePowerError: LocalizedError {
    case unauthorized
    case switchUnavailable

    var errorDescription: String? {
        switch self {
        case .unauthorized: "ClimateMap does not have access to Apple Home."
        case .switchUnavailable: "The selected Apple Home switch is unavailable."
        }
    }
}

@MainActor
final class AppleHomePowerProvider: NSObject,
    @preconcurrency HMHomeManagerDelegate,
    @preconcurrency HMAccessoryDelegate {
    typealias SnapshotHandler = ([AppleHomePowerSwitch], AppleHomeAccessState) -> Void

    var onSnapshot: SnapshotHandler?

    private var homeManager: HMHomeManager?
    private var powerCharacteristics: [String: HMCharacteristic] = [:]
    private var latestSwitches: [AppleHomePowerSwitch] = []
    private(set) var accessState: AppleHomeAccessState = .notDetermined
    private var isRefreshing = false

    func start() {
        guard homeManager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        homeManager = manager
        publishAuthorization(from: manager)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let homeManager else {
            start()
            return
        }

        publishAuthorization(from: homeManager)
        guard accessState.isAuthorized else {
            powerCharacteristics = [:]
            latestSwitches = []
            onSnapshot?([], accessState)
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        var characteristics: [String: HMCharacteristic] = [:]
        var switches: [AppleHomePowerSwitch] = []

        for home in homeManager.homes {
            for accessory in home.accessories {
                accessory.delegate = self
                for service in accessory.services where Self.isPowerSwitchService(service) {
                    guard let characteristic = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypePowerState
                            && $0.properties.contains(HMCharacteristicPropertyReadable)
                            && $0.properties.contains(HMCharacteristicPropertyWritable)
                    }) else { continue }

                    let readSucceeded = await readValue(of: characteristic)
                    let id = characteristic.uniqueIdentifier.uuidString
                    characteristics[id] = characteristic

                    if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification),
                       !characteristic.isNotificationEnabled {
                        try? await characteristic.enableNotification(true)
                    }

                    let serviceName = service.name
                    let name = serviceName.localizedCaseInsensitiveCompare(accessory.name) == .orderedSame
                        ? accessory.name
                        : "\(accessory.name) · \(serviceName)"
                    switches.append(AppleHomePowerSwitch(
                        id: id,
                        name: name,
                        roomName: accessory.room?.name ?? home.name,
                        isOn: readSucceeded && Self.booleanValue(of: characteristic),
                        isReachable: accessory.isReachable && readSucceeded
                    ))
                }
            }
        }

        powerCharacteristics = characteristics
        latestSwitches = switches.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        onSnapshot?(latestSwitches, accessState)
    }

    func setPower(_ isOn: Bool, switchID: String) async throws {
        if powerCharacteristics[switchID] == nil {
            await refresh()
        }
        guard accessState.isAuthorized else { throw AppleHomePowerError.unauthorized }
        guard let characteristic = powerCharacteristics[switchID] else {
            throw AppleHomePowerError.switchUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(isOn) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        await refresh()
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        publishAuthorization(from: manager)
        Task { await refresh() }
    }

    func homeManager(
        _ manager: HMHomeManager,
        didUpdate status: HMHomeManagerAuthorizationStatus
    ) {
        publishAuthorization(from: manager)
        Task { await refresh() }
    }

    func accessory(
        _ accessory: HMAccessory,
        service: HMService,
        didUpdateValueFor characteristic: HMCharacteristic
    ) {
        guard characteristic.characteristicType == HMCharacteristicTypePowerState else { return }
        Task { await refresh() }
    }

    private func publishAuthorization(from manager: HMHomeManager) {
        let authorization = manager.authorizationStatus
        if authorization.contains(.authorized) {
            accessState = .authorized
        } else if authorization.contains(.restricted) {
            accessState = .restricted
        } else if authorization.contains(.determined) {
            accessState = .denied
        } else {
            accessState = .notDetermined
        }
        onSnapshot?(latestSwitches, accessState)
    }

    private func readValue(of characteristic: HMCharacteristic) async -> Bool {
        await withCheckedContinuation { continuation in
            characteristic.readValue { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private static func isPowerSwitchService(_ service: HMService) -> Bool {
        service.serviceType == HMServiceTypeSwitch || service.serviceType == HMServiceTypeOutlet
    }

    private static func booleanValue(of characteristic: HMCharacteristic) -> Bool {
        (characteristic.value as? NSNumber)?.boolValue == true
    }
}
