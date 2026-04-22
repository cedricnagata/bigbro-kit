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

public final class BigBroClient: ObservableObject {
    @Published public private(set) var connectedDevice: BigBroDevice?
    @Published public private(set) var isConnected: Bool = false
    /// Devices the user has successfully paired with in the past, most
    /// recently-paired first. Persisted across launches.
    @Published public private(set) var knownDevices: [BigBroDevice] = []

    private let browser = BonjourBrowser()
    private var presenceTask: Task<Void, Never>?
    private var currentDevice: BigBroDevice? {
        didSet { connectedDevice = currentDevice }
    }

    private static let knownDevicesKey = "bigbro.knownDevices"

    public init() {
        currentDevice = loadStoredDevice()
        connectedDevice = currentDevice
        isConnected = false
        knownDevices = loadKnownDevices()
        if currentDevice != nil, tokenExists() {
            startPresence()
        }
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
                await MainActor.run {
                    self.connectedDevice = device
                    self.rememberDevice(device)
                }
                startPresence()
                return true
            case "denied":
                self.currentDevice = nil
                clearStoredDevice()
                return false
            default:
                continue
            }
        }
        throw BigBroError.timeout
    }

    /// Send messages and receive the response.
    /// - Parameters:
    ///   - messages: The conversation history to send.
    ///   - streaming: `true` (default) streams tokens as they arrive; `false` yields the full response as one chunk.
    public func send(_ messages: [Message], streaming: Bool = true) -> AsyncThrowingStream<String, Error> {
        guard let device = currentDevice else {
            return AsyncThrowingStream { $0.finish(throwing: BigBroError.notPaired) }
        }
        guard let token = KeychainTokenStore.shared.token(for: device.id) else {
            return AsyncThrowingStream { $0.finish(throwing: BigBroError.notPaired) }
        }
        let api = BigBroAPIClient(device: device)
        if streaming {
            return api.chatStream(token: token, messages: messages)
        } else {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let reply = try await api.chat(token: token, messages: messages)
                        continuation.yield(reply)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Drop the presence stream and start a new one. Useful when the UI thinks
    /// we're disconnected (server died, network blip) and we want to re-check
    /// without waiting for the 15s read-timeout to fire.
    public func refresh() {
        guard currentDevice != nil, tokenExists() else { return }
        presenceTask?.cancel()
        startPresence()
    }

    public func disconnect() {
        guard let device = currentDevice else { return }
        presenceTask?.cancel()
        presenceTask = nil
        KeychainTokenStore.shared.delete(for: device.id)
        clearStoredDevice()
        currentDevice = nil
        connectedDevice = nil
        isConnected = false
    }

    // MARK: - Presence

    /// Open one presence stream. When it ends (server closed, network drop,
    /// read-timeout fired), mark disconnected and stop — no auto-retry.
    /// Callers use `refresh()` to reconnect.
    private func startPresence() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            guard let self else { return }
            guard let device = self.currentDevice,
                  let token = KeychainTokenStore.shared.token(for: device.id) else {
                await MainActor.run { self.isConnected = false }
                return
            }
            let api = BigBroAPIClient(device: device)
            do {
                try await api.streamPresence(token: token) {
                    Task { @MainActor [weak self] in self?.isConnected = true }
                }
            } catch {
                print("[BigBroKit] presence stream error: \(error)")
            }
            await MainActor.run { [weak self] in self?.isConnected = false }
        }
    }

    // MARK: - Deprecated aliases

    @available(*, deprecated, renamed: "send(_:streaming:)")
    public func chatStream(_ messages: [Message]) -> AsyncThrowingStream<String, Error> {
        send(messages, streaming: true)
    }

    @available(*, deprecated, renamed: "send(_:streaming:)")
    public func chat(_ messages: [Message]) async throws -> String {
        guard let device = currentDevice else { throw BigBroError.notPaired }
        guard let token = KeychainTokenStore.shared.token(for: device.id) else {
            throw BigBroError.notPaired
        }
        return try await BigBroAPIClient(device: device).chat(token: token, messages: messages)
    }

    // MARK: - Private helpers

    private func tokenExists() -> Bool {
        guard let device = currentDevice else { return false }
        return KeychainTokenStore.shared.token(for: device.id) != nil
    }

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

    private func clearStoredDevice() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "bigbro.device.id")
        defaults.removeObject(forKey: "bigbro.device.name")
        defaults.removeObject(forKey: "bigbro.device.host")
        defaults.removeObject(forKey: "bigbro.device.port")
    }

    private func rememberDevice(_ device: BigBroDevice) {
        var list = knownDevices.filter { $0.id != device.id }
        list.insert(device, at: 0)
        knownDevices = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.knownDevicesKey)
        }
    }

    private func loadKnownDevices() -> [BigBroDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.knownDevicesKey),
              let list = try? JSONDecoder().decode([BigBroDevice].self, from: data) else {
            return []
        }
        return list
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
