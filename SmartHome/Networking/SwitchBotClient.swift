import CryptoKit
import Foundation

struct SwitchBotCredentials: Sendable {
    let token: String
    let secret: String

    static func bundled(bundle: Bundle = .main) throws -> SwitchBotCredentials {
        guard let token = bundle.object(forInfoDictionaryKey: "SwitchBotToken") as? String,
              let secret = bundle.object(forInfoDictionaryKey: "SwitchBotSecret") as? String,
              !token.isEmpty, !secret.isEmpty,
              !token.contains("$("), !secret.contains("$(")
        else { throw SwitchBotError.missingCredentials }
        return SwitchBotCredentials(token: token, secret: secret)
    }
}

struct SwitchBotDevice: Decodable, Identifiable, Sendable {
    let deviceId: String
    let deviceName: String
    let deviceType: String
    let enableCloudService: Bool?
    let hubDeviceId: String?

    var id: String { deviceId }
    var isMeter: Bool { deviceType.localizedCaseInsensitiveContains("meter") }
}

struct SwitchBotInfraredRemote: Decodable, Identifiable, Sendable {
    let deviceId: String
    let deviceName: String
    let remoteType: String
    let hubDeviceId: String?

    var id: String { deviceId }
}

struct SwitchBotMeterStatus: Decodable, Sendable {
    let deviceId: String
    let deviceType: String
    let temperature: Double
    let humidity: Int
    let battery: Int
}

struct SwitchBotDeviceList: Decodable, Sendable {
    let deviceList: [SwitchBotDevice]
    let infraredRemoteList: [SwitchBotInfraredRemote]
}

private struct SwitchBotEnvelope<Body: Decodable & Sendable>: Decodable, Sendable {
    let statusCode: Int
    let body: Body
    let message: String
}

private struct SwitchBotCommandEnvelope: Decodable, Sendable {
    let statusCode: Int
    let message: String
}

private struct SwitchBotCommand: Encodable, Sendable {
    let command: String
    let parameter = "default"
    let commandType = "customize"
}

enum SwitchBotError: LocalizedError, Sendable {
    case missingCredentials
    case invalidResponse
    case api(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "SwitchBot credentials are missing from the app bundle."
        case .invalidResponse:
            "SwitchBot returned an invalid response."
        case let .api(_, message):
            message
        }
    }
}

actor SwitchBotClient {
    private let credentials: SwitchBotCredentials
    private let session: URLSession
    private let baseURL = URL(string: "https://api.switch-bot.com/v1.1")!

    init(credentials: SwitchBotCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func devices() async throws -> SwitchBotDeviceList {
        try await get(path: "devices", as: SwitchBotDeviceList.self)
    }

    func meterStatus(deviceID: String) async throws -> SwitchBotMeterStatus {
        try await get(path: "devices/\(deviceID)/status", as: SwitchBotMeterStatus.self)
    }

    func sendCustomCommand(_ command: String, deviceID: String) async throws {
        let body = try JSONEncoder().encode(SwitchBotCommand(command: command))
        var request = signedRequest(path: "devices/\(deviceID)/commands", method: "POST")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(SwitchBotCommandEnvelope.self, from: data)
        else { throw SwitchBotError.invalidResponse }
        guard envelope.statusCode == 100 else {
            throw SwitchBotError.api(code: envelope.statusCode, message: envelope.message)
        }
    }

    private func get<Body: Decodable & Sendable>(path: String, as type: Body.Type) async throws -> Body {
        let (data, response) = try await session.data(for: signedRequest(path: path, method: "GET"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(SwitchBotEnvelope<Body>.self, from: data)
        else { throw SwitchBotError.invalidResponse }
        guard envelope.statusCode == 100 else {
            throw SwitchBotError.api(code: envelope.statusCode, message: envelope.message)
        }
        return envelope.body
    }

    private func signedRequest(path: String, method: String) -> URLRequest {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let nonce = UUID().uuidString
        let payload = Data("\(credentials.token)\(timestamp)\(nonce)".utf8)
        let key = SymmetricKey(data: Data(credentials.secret.utf8))
        let authentication = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        let signature = Data(authentication).base64EncodedString()

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue(credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue(signature, forHTTPHeaderField: "sign")
        request.setValue(nonce, forHTTPHeaderField: "nonce")
        request.setValue(timestamp, forHTTPHeaderField: "t")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
