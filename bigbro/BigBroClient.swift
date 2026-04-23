import Foundation
import UIKit

public enum BigBroError: Error, LocalizedError {
    case notPaired
    case networkError

    public var errorDescription: String? {
        switch self {
        case .notPaired: return "Not paired with a BigBro device."
        case .networkError: return "Network error."
        }
    }
}

public enum ConnectionState: Equatable {
    case disconnected
    case reconnecting   // path degraded; still showing UI, waiting for recovery or timeout
    case connected
}

private enum ChatStreamEvent {
    case delta(String)
    case toolCalls([[String: Any]])
}

private final class RequestHolder: @unchecked Sendable {
    var continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation?
}

/// Session-scoped client for BigBro. No persistence — every launch starts
/// disconnected. The Mac remembers approved devices and auto-approves reconnects,
/// so re-pairing is instant and silent.
@MainActor
public final class BigBroClient: ObservableObject {
    @Published public private(set) var connectedDevice: BigBroDevice?
    @Published public private(set) var connectionState: ConnectionState = .disconnected

    /// Convenience accessor; true only when fully connected (not reconnecting).
    public var isConnected: Bool { connectionState == .connected }

    private let browser = BonjourBrowser()
    private var peerConnection: PeerConnection?
    private var messageTask: Task<Void, Never>?
    private let activeRequest = RequestHolder()

    public init() {
        print("[BigBroClient] Initialized")
    }

    // MARK: - Public API

    public func discover() async -> [BigBroDevice] {
        print("[BigBroClient] Starting Bonjour discovery")
        let devices = await browser.discover()
        print("[BigBroClient] Discovered \(devices.count) device(s): \(devices.map { $0.name })")
        return devices
    }

    public func pair(with device: BigBroDevice) async throws -> Bool {
        print("[BigBroClient] Pairing with \(device.name) at \(device.host):\(device.port)")
        let conn = PeerConnection()
        try await conn.connect(host: device.host, port: UInt16(device.port))
        print("[BigBroClient] TCP connected, sending hello")
        let approved = try await conn.sendHello(deviceId: deviceId(), deviceName: UIDevice.current.name)
        print("[BigBroClient] pair result: \(approved ? "approved" : "denied")")
        if approved {
            peerConnection = conn
            connectedDevice = device
            connectionState = .connected
            startMessageLoop(conn: conn)
            await conn.startHeartbeat()
            print("[BigBroClient] Paired and heartbeat started")
        }
        return approved
    }

    public func send(_ messages: [Message], streaming: Bool = true, tools: [BigBroTool] = []) -> AsyncThrowingStream<String, Error> {
        guard let conn = peerConnection else {
            print("[BigBroClient] send: not paired")
            return AsyncThrowingStream { $0.finish(throwing: BigBroError.notPaired) }
        }
        print("[BigBroClient] send: \(messages.count) message(s), streaming=\(streaming), tools=\(tools.count)")
        return AsyncThrowingStream { continuation in
            Task { [conn] in
                var workingMessages = messages.map { $0.toDict() }
                do {
                    while true {
                        let requestId = UUID().uuidString
                        print("[BigBroClient] Request \(requestId.prefix(8)): sending to Mac")
                        let eventStream = AsyncThrowingStream<ChatStreamEvent, Error> { cont in
                            self.activeRequest.continuation = cont
                        }
                        var msg: [String: Any] = [
                            "type": "request",
                            "requestId": requestId,
                            "messages": workingMessages,
                            "streaming": streaming,
                        ]
                        if !tools.isEmpty {
                            msg["tools"] = try tools.map { t -> Any in
                                let d = try JSONEncoder().encode(t.definition)
                                return try JSONSerialization.jsonObject(with: d)
                            }
                        }
                        try await conn.send(msg)

                        var accumulated = ""
                        var pendingToolCalls: [[String: Any]]? = nil
                        for try await event in eventStream {
                            switch event {
                            case .delta(let text):
                                if streaming { continuation.yield(text) } else { accumulated += text }
                            case .toolCalls(let calls):
                                print("[BigBroClient] Tool calls received: \(calls.count)")
                                pendingToolCalls = calls
                            }
                        }
                        guard let calls = pendingToolCalls else {
                            print("[BigBroClient] Request \(requestId.prefix(8)): done")
                            if !streaming { continuation.yield(accumulated) }
                            break
                        }
                        print("[BigBroClient] Executing \(calls.count) tool call(s)")
                        workingMessages.append(["role": "assistant", "content": "", "tool_calls": calls])
                        for call in calls {
                            guard let fn = call["function"] as? [String: Any],
                                  let name = fn["name"] as? String else { continue }
                            let args = (fn["arguments"] as? [String: Any]) ?? [:]
                            print("[BigBroClient] Calling tool: \(name)")
                            if let tool = tools.first(where: { $0.definition.function.name == name }) {
                                let result = await tool.handler(args)
                                workingMessages.append(["role": "tool", "content": result, "tool_name": name])
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    print("[BigBroClient] send error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func disconnect() {
        print("[BigBroClient] disconnect called")
        messageTask?.cancel()
        messageTask = nil
        Task { await peerConnection?.disconnect() }
        teardown()
    }

    // MARK: - Private

    private func startMessageLoop(conn: PeerConnection) {
        messageTask?.cancel()
        messageTask = Task { [weak self, conn] in
            print("[BigBroClient] Message loop started")
            let stream = await conn.messages()
            do {
                for try await msg in stream {
                    guard let self else { return }
                    self.dispatch(msg)
                }
            } catch {
                print("[BigBroClient] Message loop error: \(error)")
            }
            print("[BigBroClient] Message loop ended, tearing down")
            await MainActor.run { [weak self] in self?.teardown() }
        }
    }

    private func dispatch(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        print("[BigBroClient] dispatch: \(type)")
        switch type {
        case "_reconnecting":
            connectionState = .reconnecting
        case "_connected":
            connectionState = .connected
        case "chunk":
            if let delta = msg["delta"] as? String {
                activeRequest.continuation?.yield(.delta(delta))
            }
        case "toolCall":
            if let calls = msg["calls"] as? [[String: Any]] {
                activeRequest.continuation?.yield(.toolCalls(calls))
            }
        case "done":
            activeRequest.continuation?.finish()
            activeRequest.continuation = nil
        case "error":
            let errMsg = msg["message"] as? String ?? "unknown"
            print("[BigBroClient] Server error: \(errMsg)")
            activeRequest.continuation?.finish(throwing: BigBroError.networkError)
            activeRequest.continuation = nil
        default:
            print("[BigBroClient] dispatch: unhandled type '\(type)'")
        }
    }

    private func teardown() {
        print("[BigBroClient] teardown: connectionState → .disconnected")
        connectionState = .disconnected
        connectedDevice = nil
        peerConnection = nil
    }

    private func deviceId() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }
}
