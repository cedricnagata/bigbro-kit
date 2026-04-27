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
    @Published public private(set) var missingModels: [String] = []
    /// Bonjour service names of Macs the user has previously paired with.
    @Published public private(set) var pairedDeviceNames: Set<String> = []
    /// Whether auto-reconnect is currently active.
    @Published public private(set) var autoReconnectEnabled: Bool = false

    /// Convenience accessor; true only when fully connected (not reconnecting).
    public var isConnected: Bool { connectionState == .connected }

    private let browser = BonjourBrowser()
    private let continuousBrowser = ContinuousBonjourBrowser()
    private let pairedStore = PairedDeviceStore()
    private var peerConnection: PeerConnection?
    private var messageTask: Task<Void, Never>?
    private var autoReconnectTask: Task<Void, Never>?
    private var pendingPairTask: Task<Void, Never>?
    private let activeRequest = RequestHolder()
    private let requiredModels: [String]
    private let appName: String
    private var didRegisterLifecycleObservers = false

    public init(appName: String, requiredModels: [String] = []) {
        self.appName = appName
        self.requiredModels = requiredModels
        self.pairedDeviceNames = pairedStore.ids()
        print("[BigBroClient] Initialized app='\(appName)' with \(requiredModels.count) required model(s), \(pairedDeviceNames.count) paired Mac(s)")
        registerLifecycleObserversIfNeeded()
    }

    // MARK: - Public API

    public func discover() async -> [BigBroDevice] {
        print("[BigBroClient] Starting Bonjour discovery")
        let devices = await browser.discover()
        print("[BigBroClient] Discovered \(devices.count) device(s): \(devices.map { $0.name })")
        return devices
    }

    public func pair(with device: BigBroDevice) async throws -> Bool {
        // Manual pair wins over any in-flight auto-pair attempt.
        pendingPairTask?.cancel()
        pendingPairTask = nil
        return try await pairInternal(with: device)
    }

    private func pairInternal(with device: BigBroDevice) async throws -> Bool {
        print("[BigBroClient] Pairing with \(device.name) at \(device.host):\(device.port)")
        let conn = PeerConnection()
        try await conn.connect(host: device.host, port: UInt16(device.port))
        print("[BigBroClient] TCP connected, sending hello")
        let ack = try await conn.sendHello(deviceId: deviceId(), deviceName: UIDevice.current.name, appName: appName, requiredModels: requiredModels)
        print("[BigBroClient] pair result: approved=\(ack.approved) missing=\(ack.missingModels)")
        if ack.approved {
            peerConnection = conn
            connectedDevice = device
            connectionState = .connected
            missingModels = ack.missingModels
            startMessageLoop(conn: conn)
            rememberDevice(device)
            print("[BigBroClient] Paired")
        } else {
            await conn.disconnect()
        }
        return ack.approved
    }

    // MARK: - Auto-reconnect

    /// Start watching for any previously-paired Mac and automatically pair when
    /// one appears. Safe to call repeatedly. Persists the enabled flag so the
    /// SDK resumes auto-reconnect on next launch.
    public func enableAutoReconnect() {
        guard !autoReconnectEnabled else { return }
        autoReconnectEnabled = true
        pairedStore.autoReconnectEnabled = true
        print("[BigBroClient] enableAutoReconnect (paired count=\(pairedDeviceNames.count))")
        startAutoReconnectLoop()
    }

    public func disableAutoReconnect() {
        guard autoReconnectEnabled else { return }
        autoReconnectEnabled = false
        pairedStore.autoReconnectEnabled = false
        print("[BigBroClient] disableAutoReconnect")
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        pendingPairTask?.cancel()
        pendingPairTask = nil
        continuousBrowser.stop()
    }

    public func forgetDevice(_ name: String) {
        pairedStore.remove(name)
        pairedDeviceNames = pairedStore.ids()
        print("[BigBroClient] forgetDevice: \(name) (remaining=\(pairedDeviceNames.count))")
    }

    public func forgetAllDevices() {
        pairedStore.removeAll()
        pairedDeviceNames = []
        print("[BigBroClient] forgetAllDevices")
    }

    /// Resumes auto-reconnect if it was previously enabled. Apps that opt in
    /// once should call this on launch to restore the behavior.
    public func resumeAutoReconnectIfEnabled() {
        if pairedStore.autoReconnectEnabled && !autoReconnectEnabled {
            enableAutoReconnect()
        }
    }

    /// Send a chat request to the paired Mac, proxied to Ollama's `/api/chat`.
    ///
    /// - Parameters:
    ///   - messages: Conversation history, including any tool results.
    ///   - model: Override the Mac's default model for this request.
    ///   - streaming: When `true` (default), yields text deltas as they arrive.
    ///   - tools: Tools the model may call; the agentic loop runs transparently.
    ///   - format: Constrain the response to JSON or a specific JSON schema.
    ///   - options: Low-level Ollama model parameters (temperature, top_k, etc.).
    ///   - think: Enable chain-of-thought reasoning (supported models only).
    ///   - keepAlive: How long Ollama should keep the model loaded after the request.
    public func chat(
        _ messages: [Message],
        model: String? = nil,
        streaming: Bool = true,
        tools: [BigBroTool] = [],
        format: OllamaFormat? = nil,
        options: OllamaOptions? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        guard let conn = peerConnection else {
            print("[BigBroClient] chat: not paired")
            return AsyncThrowingStream { $0.finish(throwing: BigBroError.notPaired) }
        }
        print("[BigBroClient] chat: \(messages.count) message(s), streaming=\(streaming), tools=\(tools.count)")
        return AsyncThrowingStream { continuation in
            // Cancel any in-flight request before taking over activeRequest
            self.activeRequest.continuation?.finish(throwing: CancellationError())
            Task { [conn] in
                var workingMessages = messages.map { $0.toDict() }
                // Encode tool definitions once — they don't change between loop iterations
                let encodedTools: [Any] = (try? tools.map { t -> Any in
                    let d = try JSONEncoder().encode(t.definition)
                    return try JSONSerialization.jsonObject(with: d)
                }) ?? []
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
                        if !encodedTools.isEmpty { msg["tools"] = encodedTools }
                        if let model     { msg["model"] = model }
                        if let format    { msg["format"] = format.toJSONValue() }
                        if let options   { msg["options"] = options.toDict() }
                        if let think     { msg["think"] = think }
                        if let keepAlive { msg["keep_alive"] = keepAlive }
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
                        workingMessages.append(Message(role: .assistant, content: "", toolCalls: calls).toDict())
                        for call in calls {
                            guard let fn = call["function"] as? [String: Any],
                                  let name = fn["name"] as? String else {
                                print("[BigBroClient] Malformed tool call, appending empty result")
                                workingMessages.append(Message.tool(name: "unknown", content: "error: malformed tool call").toDict())
                                continue
                            }
                            let args = (fn["arguments"] as? [String: Any]) ?? [:]
                            print("[BigBroClient] Calling tool: \(name)")
                            if let tool = tools.first(where: { $0.definition.function.name == name }) {
                                let result = await tool.handler(args)
                                workingMessages.append(Message.tool(name: name, content: result).toDict())
                            } else {
                                workingMessages.append(Message.tool(name: name, content: "error: unknown tool '\(name)'").toDict())
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

    /// Send a raw generation request to the paired Mac, proxied to Ollama's `/api/generate`.
    ///
    /// Unlike `chat()`, there is no tool-call loop — `/api/generate` does not support tools.
    ///
    /// - Parameters:
    ///   - prompt: The prompt string to generate a response for.
    ///   - images: Images to include with the request (multimodal models only).
    ///   - suffix: Text to append after the model's response.
    ///   - system: Override the system prompt for this request.
    ///   - template: Override the prompt template.
    ///   - model: Override the Mac's default model for this request.
    ///   - format: Constrain the response to JSON or a specific JSON schema.
    ///   - options: Low-level Ollama model parameters.
    ///   - raw: When `true`, skip prompt formatting.
    ///   - think: Enable chain-of-thought reasoning.
    ///   - keepAlive: How long Ollama should keep the model loaded after the request.
    ///   - streaming: When `true` (default), yields text deltas as they arrive.
    public func generate(
        prompt: String,
        images: [Data] = [],
        suffix: String? = nil,
        system: String? = nil,
        template: String? = nil,
        model: String? = nil,
        format: OllamaFormat? = nil,
        options: OllamaOptions? = nil,
        raw: Bool? = nil,
        think: Bool? = nil,
        keepAlive: String? = nil,
        streaming: Bool = true
    ) -> AsyncThrowingStream<String, Error> {
        guard let conn = peerConnection else {
            print("[BigBroClient] generate: not paired")
            return AsyncThrowingStream { $0.finish(throwing: BigBroError.notPaired) }
        }
        print("[BigBroClient] generate: prompt='\(prompt.prefix(40))…', streaming=\(streaming)")
        return AsyncThrowingStream { continuation in
            Task { [conn] in
                let requestId = UUID().uuidString
                let eventStream = AsyncThrowingStream<ChatStreamEvent, Error> { cont in
                    self.activeRequest.continuation = cont
                }
                var msg: [String: Any] = [
                    "type": "generateRequest",
                    "requestId": requestId,
                    "prompt": prompt,
                    "streaming": streaming,
                ]
                if !images.isEmpty {
                    msg["images"] = images.map { $0.base64EncodedString() }
                }
                if let suffix    { msg["suffix"] = suffix }
                if let system    { msg["system"] = system }
                if let template  { msg["template"] = template }
                if let model     { msg["model"] = model }
                if let format    { msg["format"] = format.toJSONValue() }
                if let options   { msg["options"] = options.toDict() }
                if let raw       { msg["raw"] = raw }
                if let think     { msg["think"] = think }
                if let keepAlive { msg["keep_alive"] = keepAlive }
                do {
                    try await conn.send(msg)
                    var accumulated = ""
                    for try await event in eventStream {
                        switch event {
                        case .delta(let text):
                            if streaming { continuation.yield(text) } else { accumulated += text }
                        case .toolCalls:
                            break // /api/generate does not emit tool calls; ignore defensively
                        }
                    }
                    if !streaming { continuation.yield(accumulated) }
                    continuation.finish()
                } catch {
                    print("[BigBroClient] generate error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func disconnect() {
        print("[BigBroClient] disconnect called")
        messageTask?.cancel()
        messageTask = nil
        let conn = peerConnection  // capture before teardown() clears it
        teardown()
        Task { await conn?.disconnect() }
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
        case "modelsUpdate":
            missingModels = msg["missingModels"] as? [String] ?? []
            print("[BigBroClient] modelsUpdate: missing=\(missingModels)")
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
        missingModels = []
        peerConnection = nil
        if autoReconnectEnabled {
            // Re-arm the browse so currently-visible Macs trigger a fresh
            // `.appeared` event and we attempt to reconnect immediately.
            print("[BigBroClient] teardown: re-arming auto-reconnect browse")
            startAutoReconnectLoop()
        }
    }

    private func rememberDevice(_ device: BigBroDevice) {
        pairedStore.add(id: device.id, name: device.name)
        pairedDeviceNames = pairedStore.ids()
        print("[BigBroClient] Remembered \(device.name) (total=\(pairedDeviceNames.count))")
    }

    private func startAutoReconnectLoop() {
        autoReconnectTask?.cancel()
        let stream = continuousBrowser.start()
        autoReconnectTask = Task { @MainActor [weak self] in
            print("[BigBroClient] Auto-reconnect loop started")
            for await event in stream {
                guard let self else { return }
                if Task.isCancelled { break }
                switch event {
                case .appeared(let device):
                    self.handleDeviceAppeared(device)
                case .disappeared:
                    break
                }
            }
            print("[BigBroClient] Auto-reconnect loop ended")
        }
    }

    private func handleDeviceAppeared(_ device: BigBroDevice) {
        guard autoReconnectEnabled else { return }
        guard peerConnection == nil else { return }
        guard pendingPairTask == nil else { return }
        guard pairedStore.contains(device.id) else {
            print("[BigBroClient] Auto-reconnect: ignoring unknown \(device.name)")
            return
        }
        print("[BigBroClient] Auto-reconnect: attempting \(device.name)")
        pendingPairTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingPairTask = nil }
            do {
                _ = try await self.pairInternal(with: device)
            } catch {
                print("[BigBroClient] Auto-reconnect: pair failed for \(device.name): \(error)")
            }
        }
    }

    private func registerLifecycleObserversIfNeeded() {
        guard !didRegisterLifecycleObservers else { return }
        didRegisterLifecycleObservers = true
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnteredBackground() }
        }
        nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnteringForeground() }
        }
    }

    private func handleEnteredBackground() {
        guard autoReconnectEnabled else { return }
        print("[BigBroClient] App backgrounded — pausing auto-reconnect browse")
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        continuousBrowser.stop()
    }

    private func handleEnteringForeground() {
        guard autoReconnectEnabled, autoReconnectTask == nil else { return }
        print("[BigBroClient] App foregrounding — resuming auto-reconnect browse")
        startAutoReconnectLoop()
    }

    private func deviceId() -> String {
        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        // Combine vendor + bundle so two apps on the same device get distinct IDs
        return "\(vendor).\(bundle)"
    }
}
