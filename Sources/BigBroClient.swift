import Foundation
import NaturalLanguage
import UIKit

public enum BigBroError: Error, LocalizedError {
    case notPaired
    case networkError
    /// The Mac reported a failure for this request. The message comes from the Mac and is
    /// meant to be actionable — a missing model, a speech backend that isn't running.
    case serverError(String)
    /// The Mac doesn't have the requested model installed and is downloading
    /// it. Watch `BigBroClient.modelDownloads` for progress.
    case modelDownloading(model: String, alreadyInProgress: Bool)

    public var errorDescription: String? {
        switch self {
        case .notPaired: return "Not paired with a BigBro device."
        case .networkError: return "Network error."
        case .serverError(let message): return message
        case .modelDownloading(let model, let alreadyInProgress):
            return alreadyInProgress
                ? "Model '\(model)' is still downloading on the Mac."
                : "Model '\(model)' is not downloaded — started downloading on the Mac."
        }
    }
}

public enum ConnectionState: Equatable {
    case disconnected
    case reconnecting   // path degraded; still showing UI, waiting for recovery or timeout
    case connected
}

/// One message from the Mac, already matched to the request that asked for it.
private enum PeerEvent {
    case delta(String)
    case thinking(String)
    case toolCalls([[String: Any]])
    case audioStart(format: String, sampleRate: Int, channels: Int)
    case audio(Data)
    case transcript(text: String, language: String?)
}

/// Routes inbound messages to the request waiting for them, keyed by `requestId`.
///
/// A single slot is not enough: speech overlaps chat by construction, since `converse()`
/// speaks each finished sentence while the chat response is still streaming. With one slot
/// the second request's continuation replaces the first, and the first stream never
/// completes.
private final class RequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: AsyncThrowingStream<PeerEvent, Error>.Continuation] = [:]

    func register(_ requestId: String, _ continuation: AsyncThrowingStream<PeerEvent, Error>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        continuations[requestId] = continuation
    }

    func yield(_ requestId: String, _ event: PeerEvent) {
        lock.lock()
        let continuation = continuations[requestId]
        lock.unlock()
        continuation?.yield(event)
    }

    func finish(_ requestId: String, throwing error: Error? = nil) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: requestId)
        lock.unlock()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    /// Fails every in-flight request — used when the connection drops, so no caller is left
    /// awaiting a stream that can never complete.
    func finishAll(throwing error: Error) {
        lock.lock()
        let all = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in all.values { continuation.finish(throwing: error) }
    }
}

/// Session-scoped client for BigBro. No persistence — every launch starts
/// disconnected. The Mac remembers approved devices and auto-approves reconnects,
/// so re-pairing is instant and silent.
@MainActor
public final class BigBroClient: ObservableObject {
    @Published public private(set) var connectedDevice: BigBroDevice?
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var missingModels: [String] = []
    /// Live download progress for any model the Mac is pulling. Updated
    /// continuously while pulls are active; entries are removed shortly after
    /// completion.
    @Published public private(set) var modelDownloads: [String: ModelDownloadProgress] = [:]
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
    private let requests = RequestRegistry()
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
                        let eventStream = AsyncThrowingStream<PeerEvent, Error> { cont in
                            self.requests.register(requestId, cont)
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
                            default:
                                break  // audio and transcripts belong to other requests
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
                let eventStream = AsyncThrowingStream<PeerEvent, Error> { cont in
                    self.requests.register(requestId, cont)
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
                        default:
                            break  // generate emits no tool calls, audio or transcripts
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

    // MARK: - Speech

    /// Streams synthesized audio for `text` from the Mac's speech backend.
    ///
    /// Chunks are raw payload in the negotiated format — `pcm` by default, which is 24 kHz
    /// 16-bit signed little-endian mono and carries no header, so append them in order and
    /// feed them straight to `AVAudioPlayerNode`.
    ///
    /// Independently useful: speaking a canned string costs no LLM call.
    public func speak(
        _ text: String,
        voice: String? = nil,
        model: String? = nil,
        responseFormat: String? = nil,
        speed: Double? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        guard let conn = peerConnection else {
            print("[BigBroClient] speak: not paired")
            return AsyncThrowingStream { $0.finish(throwing: BigBroError.notPaired) }
        }
        return AsyncThrowingStream { continuation in
            Task { [conn] in
                let requestId = UUID().uuidString
                let eventStream = AsyncThrowingStream<PeerEvent, Error> { cont in
                    self.requests.register(requestId, cont)
                }
                var msg: [String: Any] = [
                    "type": "speechRequest",
                    "requestId": requestId,
                    "input": text,
                ]
                if let voice          { msg["voice"] = voice }
                if let model          { msg["model"] = model }
                if let responseFormat { msg["response_format"] = responseFormat }
                if let speed          { msg["speed"] = speed }

                do {
                    try await conn.send(msg)
                    for try await event in eventStream {
                        switch event {
                        case .audio(let data):
                            continuation.yield(data)
                        case .audioStart(let format, let sampleRate, let channels):
                            print("[BigBroClient] audio \(format) \(sampleRate)Hz x\(channels) for \(requestId.prefix(8))")
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    print("[BigBroClient] speak error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Transcribes a complete recorded utterance.
    ///
    /// Batch, not streaming: record a turn, then send it. `format` should match the
    /// container the audio is actually in — the Mac uses it for both the filename and the
    /// MIME type it declares upstream.
    public func transcribe(
        _ audio: Data,
        format: String = "wav",
        model: String? = nil,
        language: String? = nil
    ) async throws -> String {
        guard let conn = peerConnection else {
            print("[BigBroClient] transcribe: not paired")
            throw BigBroError.notPaired
        }
        let requestId = UUID().uuidString
        let eventStream = AsyncThrowingStream<PeerEvent, Error> { cont in
            self.requests.register(requestId, cont)
        }
        var msg: [String: Any] = [
            "type": "transcribeRequest",
            "requestId": requestId,
            "audio": audio.base64EncodedString(),
            "audioFormat": format,
        ]
        if let model    { msg["model"] = model }
        if let language { msg["language"] = language }

        print("[BigBroClient] transcribe: \(audio.count) bytes of \(format)")
        try await conn.send(msg)

        var text = ""
        for try await event in eventStream {
            if case .transcript(let transcribed, _) = event { text = transcribed }
        }
        return text
    }

    // MARK: - Voice loop

    public enum ConverseEvent {
        case text(String)
        case audio(Data)
    }

    /// Runs a chat turn and speaks the answer as it arrives.
    ///
    /// Speech is pipelined per sentence rather than waiting for the whole response, so time
    /// to first audio is one sentence plus synthesis rather than a full generation.
    ///
    /// This is a composition over `chat()` and `speak()` rather than a server-side mode
    /// because the tool-calling loop runs here: only the client knows which turn is a final
    /// answer and which is an intermediate tool step, so only the client can decide what is
    /// worth speaking.
    public func converse(
        _ messages: [Message],
        voice: String? = nil,
        tools: [BigBroTool] = [],
        model: String? = nil,
        options: OllamaOptions? = nil
    ) -> AsyncThrowingStream<ConverseEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Sentences are spoken strictly in order. Concurrent speech requests can
                // finish out of order, which would shuffle the audio.
                let (sentences, enqueue) = AsyncStream<String>.makeStream()

                let speaker = Task {
                    for await sentence in sentences {
                        do {
                            for try await audio in self.speak(sentence, voice: voice) {
                                continuation.yield(.audio(audio))
                            }
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }

                do {
                    var buffer = ""
                    for try await delta in self.chat(messages, model: model, tools: tools, options: options) {
                        continuation.yield(.text(delta))
                        buffer += delta
                        while let sentence = Self.takeSentence(&buffer) {
                            if let speakable = Self.speakable(sentence) { enqueue.yield(speakable) }
                        }
                    }
                    if let speakable = Self.speakable(buffer) { enqueue.yield(speakable) }
                    enqueue.finish()
                    await speaker.value
                    continuation.finish()
                } catch {
                    enqueue.finish()
                    speaker.cancel()
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Removes the leading complete sentence from `buffer`, leaving any partial tail.
    ///
    /// Uses `NLTokenizer` rather than splitting on "." — decimals, abbreviations and
    /// ellipses all defeat naive splitting. A sentence only counts as complete once another
    /// has started behind it, since the final one is still being written to.
    private static func takeSentence(_ buffer: inout String) -> String? {
        guard !buffer.isEmpty else { return nil }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = buffer

        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: buffer.startIndex..<buffer.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        guard ranges.count > 1, let first = ranges.first else { return nil }

        let sentence = String(buffer[first])
        buffer = String(buffer[first.upperBound...])
        return sentence
    }

    /// Prepares text for synthesis, or returns nil when nothing is left worth speaking.
    ///
    /// Code fences, link targets, bare URLs and table pipes are all noise read aloud.
    private static func speakable(_ text: String) -> String? {
        var out = text
        let substitutions: [(pattern: String, replacement: String)] = [
            ("```[\\s\\S]*?```", " "),                  // fenced code
            ("`([^`]*)`", "$1"),                        // inline code
            ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),       // links: keep the label
            ("https?://\\S+", " "),                     // bare URLs
            ("[*_#>|~]", " "),                          // emphasis, headings, table pipes
            ("\\s+", " "),
        ]
        for (pattern, replacement) in substitutions {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
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
        // Audio arrives several times a second; logging every frame drowns the console.
        if type != "audioChunk" { print("[BigBroClient] dispatch: \(type)") }

        // Connection- and device-level messages carry no requestId.
        switch type {
        case "_reconnecting":
            connectionState = .reconnecting
            return
        case "_connected":
            connectionState = .connected
            return
        case "modelsUpdate":
            missingModels = msg["missingModels"] as? [String] ?? []
            print("[BigBroClient] modelsUpdate: missing=\(missingModels)")
            return
        case "modelDownloadProgress":
            applyDownloadProgress(msg, done: false)
            return
        case "modelDownloadComplete":
            applyDownloadProgress(msg, done: true)
            return
        default:
            break
        }

        // Everything below belongs to one specific in-flight request.
        guard let requestId = msg["requestId"] as? String else {
            print("[BigBroClient] dispatch: '\(type)' arrived with no requestId")
            return
        }

        switch type {
        case "chunk":
            if let delta = msg["delta"] as? String {
                requests.yield(requestId, .delta(delta))
            }
        case "thinking":
            if let delta = msg["delta"] as? String {
                requests.yield(requestId, .thinking(delta))
            }
        case "toolCall":
            if let calls = msg["calls"] as? [[String: Any]] {
                requests.yield(requestId, .toolCalls(calls))
            }
        case "audioStart":
            requests.yield(requestId, .audioStart(
                format: msg["format"] as? String ?? "pcm",
                sampleRate: msg["sampleRate"] as? Int ?? 24_000,
                channels: msg["channels"] as? Int ?? 1
            ))
        case "audioChunk":
            if let base64 = msg["audio"] as? String, let audio = Data(base64Encoded: base64) {
                requests.yield(requestId, .audio(audio))
            }
        case "transcript":
            requests.yield(requestId, .transcript(
                text: msg["text"] as? String ?? "",
                language: msg["language"] as? String
            ))
        case "done":
            requests.finish(requestId)
        case "modelDownloading":
            // The request is blocked — the model has to be pulled first.
            let model = msg["model"] as? String ?? ""
            let already = msg["alreadyInProgress"] as? Bool ?? false
            print("[BigBroClient] modelDownloading: \(model) alreadyInProgress=\(already)")
            requests.finish(requestId, throwing: BigBroError.modelDownloading(model: model, alreadyInProgress: already))
        case "error":
            let errMsg = msg["message"] as? String ?? "unknown"
            print("[BigBroClient] Server error: \(errMsg)")
            requests.finish(requestId, throwing: BigBroError.serverError(errMsg))
        default:
            print("[BigBroClient] dispatch: unhandled type '\(type)'")
        }
    }

    private func applyDownloadProgress(_ msg: [String: Any], done: Bool) {
        guard let model = msg["model"] as? String else { return }
        let status = msg["status"] as? String ?? ""
        let completed = (msg["completed"] as? Int64) ?? Int64((msg["completed"] as? Int) ?? 0)
        let total = (msg["total"] as? Int64) ?? Int64((msg["total"] as? Int) ?? 0)
        let success = (msg["success"] as? Bool) ?? !done
        let error = msg["error"] as? String
        let progress = ModelDownloadProgress(
            model: model,
            status: status,
            bytesCompleted: completed,
            bytesTotal: total,
            done: done,
            success: success,
            error: error
        )
        modelDownloads[model] = progress
        if done {
            // Drop completed entries shortly after, mirroring the Mac side.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if self?.modelDownloads[model]?.done == true {
                    self?.modelDownloads.removeValue(forKey: model)
                }
            }
        }
    }

    private func teardown() {
        print("[BigBroClient] teardown: connectionState → .disconnected")
        connectionState = .disconnected
        connectedDevice = nil
        missingModels = []
        peerConnection = nil
        // Nothing further will arrive for in-flight requests; fail them rather than leaving
        // callers awaiting a stream that can never complete.
        requests.finishAll(throwing: BigBroError.notPaired)
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
