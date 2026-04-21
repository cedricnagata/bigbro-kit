import Foundation
import UIKit

public enum BigBroError: Error, LocalizedError {
    case notPaired
    case timeout
    case missingToken
    case networkError

    public var errorDescription: String? {
        switch self {
        case .notPaired: return "Not paired with a BigBro device."
        case .timeout: return "Pairing request timed out."
        case .missingToken: return "Approval received but no token returned."
        case .networkError: return "Network error."
        }
    }
}

public final class BigBroClient {
    private let browser = BonjourBrowser()
    private var currentDevice: BigBroDevice?

    public init() {
        currentDevice = loadStoredDevice()
    }

    // MARK: - Public API

    public func discover() async -> [BigBroDevice] {
        await browser.discover()
    }

    public func pair(with device: BigBroDevice) async throws -> Bool {
        self.currentDevice = device
        saveStoredDevice(device)

        let myId = deviceId()
        let myName = await UIDevice.current.name
        let api = BigBroAPIClient(device: device)

        try await api.sendPairRequest(deviceName: myName, deviceId: myId)

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let status = try await api.pollPairStatus(deviceId: myId)
            switch status.status {
            case "approved":
                guard let token = status.token else { throw BigBroError.missingToken }
                KeychainTokenStore.shared.save(token: token, for: device.id)
                return true
            case "denied":
                return false
            default:
                continue
            }
        }
        throw BigBroError.timeout
    }

    public func chat(_ messages: [Message]) async throws -> String {
        guard let device = currentDevice else { throw BigBroError.notPaired }
        guard let token = KeychainTokenStore.shared.token(for: device.id) else {
            throw BigBroError.notPaired
        }
        let api = BigBroAPIClient(device: device)
        return try await api.chat(token: token, messages: messages)
    }

    // MARK: - Private helpers

    private func deviceId() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }

    private func saveStoredDevice(_ device: BigBroDevice) {
        let defaults = UserDefaults.standard
        defaults.set(device.id, forKey: "bigbro.device.id")
        defaults.set(device.name, forKey: "bigbro.device.name")
        defaults.set(device.host, forKey: "bigbro.device.host")
        defaults.set(device.port, forKey: "bigbro.device.port")
    }

    private func loadStoredDevice() -> BigBroDevice? {
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: "bigbro.device.id"),
              let name = defaults.string(forKey: "bigbro.device.name"),
              let host = defaults.string(forKey: "bigbro.device.host") else { return nil }
        let port = defaults.integer(forKey: "bigbro.device.port")
        guard port > 0 else { return nil }
        return BigBroDevice(id: id, name: name, host: host, port: port)
    }
}
