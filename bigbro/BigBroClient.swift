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

/// Session-scoped client for BigBro. No persistence across launches — every
/// launch starts disconnected; the user taps Find BigBro to pair. The Mac
/// remembers devices and auto-approves known ones, so "re-pair" is silent.
public final class BigBroClient: ObservableObject {
    @Published public private(set) var connectedDevice: BigBroDevice?
    @Published public private(set) var isConnected: Bool = false

    private let browser = BonjourBrowser()
    private var presenceTask: Task<Void, Never>?
    private var currentDevice: BigBroDevice?
    private var currentToken: String?

    public init() {}

    // MARK: - Public API

    public func discover() async -> [BigBroDevice] {
        await browser.discover()
    }

    public func pair(with device: BigBroDevice) async throws -> Bool {
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
                await MainActor.run {
                    self.currentDevice = device
                    self.currentToken = token
                    self.connectedDevice = device
                }
                startPresence()
                return true
            case "denied":
                return false
            default:
                continue
            }
        }
        throw BigBroError.timeout
    }

    public func send(_ messages: [Message], streaming: Bool = true) -> AsyncThrowingStream<String, Error> {
        guard let device = currentDevice, let token = currentToken else {
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

    /// Fully disconnect: cancel the presence stream and forget the device and
    /// token. The user must Find BigBro again to reconnect.
    public func disconnect() {
        presenceTask?.cancel()
        presenceTask = nil
        teardown()
    }

    // MARK: - Presence

    /// Open one presence stream. When it ends for any reason (Mac-initiated
    /// disconnect, remove, network drop, 15s heartbeat timeout), tear down
    /// fully — iOS forgets the device and token.
    private func startPresence() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            guard let self else { return }
            guard let device = self.currentDevice, let token = self.currentToken else {
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
            await MainActor.run { [weak self] in self?.teardown() }
        }
    }

    private func teardown() {
        isConnected = false
        currentDevice = nil
        currentToken = nil
        connectedDevice = nil
    }

    // MARK: - Deprecated aliases

    @available(*, deprecated, renamed: "send(_:streaming:)")
    public func chatStream(_ messages: [Message]) -> AsyncThrowingStream<String, Error> {
        send(messages, streaming: true)
    }

    @available(*, deprecated, renamed: "send(_:streaming:)")
    public func chat(_ messages: [Message]) async throws -> String {
        guard let device = currentDevice, let token = currentToken else { throw BigBroError.notPaired }
        return try await BigBroAPIClient(device: device).chat(token: token, messages: messages)
    }

    // MARK: - Private helpers

    private func deviceId() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }
}
