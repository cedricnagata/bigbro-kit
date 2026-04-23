import Foundation
import Network

actor PeerConnection {
    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var helloAckContinuation: CheckedContinuation<Bool, Error>?
    private var msgContinuation: AsyncThrowingStream<[String: Any], Error>.Continuation?
    private var lastPongReceived: Date = Date()
    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Public API

    func connect(host: String, port: UInt16) async throws {
        print("[PeerConnection] Connecting to \(host):\(port)")
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            print("[PeerConnection] State: \(state)")
            Task { await self?.handleState(state) }
        }

        conn.viabilityUpdateHandler = { [weak self] isViable in
            print("[PeerConnection] Viability: \(isViable)")
            Task { await self?.handleViability(isViable) }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectContinuation = cont
            conn.start(queue: .global(qos: .userInitiated))
        }

        print("[PeerConnection] Connected to \(host):\(port)")
        Task { await self.readLoop() }
    }

    /// Send hello and wait for helloAck. Returns true if approved, false if denied.
    func sendHello(deviceId: String, deviceName: String) async throws -> Bool {
        print("[PeerConnection] Sending hello (deviceId=\(deviceId.prefix(8)), deviceName=\(deviceName))")
        try sendRaw(["type": "hello", "deviceId": deviceId, "deviceName": deviceName])
        print("[PeerConnection] Hello sent, waiting for helloAck")
        let result = try await withCheckedThrowingContinuation { cont in
            self.helloAckContinuation = cont
        }
        print("[PeerConnection] helloAck received: \(result ? "approved" : "denied")")
        return result
    }

    func send(_ message: [String: Any]) throws {
        guard connection != nil else {
            print("[PeerConnection] send: no connection")
            throw BigBroError.notPaired
        }
        print("[PeerConnection] → \(message["type"] ?? "?")")
        try sendRaw(message)
    }

    /// Start sending periodic pings. Call once after a successful handshake.
    /// Tears down the connection if no pong is received within 25s.
    func startHeartbeat() {
        print("[PeerConnection] Starting heartbeat (10s interval, 25s timeout)")
        lastPongReceived = Date()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { break }
                let elapsed = await self.secondsSinceLastPong()
                if elapsed > 25 {
                    print("[PeerConnection] Heartbeat timeout (\(Int(elapsed))s since last pong), closing")
                    await self.heartbeatTimeout()
                    break
                }
                print("[PeerConnection] Heartbeat ping (last pong \(Int(elapsed))s ago)")
                await self.sendPingIfAlive()
            }
        }
    }

    func disconnect() {
        print("[PeerConnection] Disconnecting (sending bye)")
        try? sendRaw(["type": "bye"])
        stopHeartbeat()
        connection?.cancel()
        connection = nil
    }

    /// Returns a stream of incoming messages (excluding helloAck, pong, bye, and internal signals).
    /// Must be called once after a successful handshake.
    func messages() -> AsyncThrowingStream<[String: Any], Error> {
        print("[PeerConnection] messages() stream created")
        let (stream, cont) = AsyncThrowingStream.makeStream(of: [String: Any].self, throwing: Error.self)
        self.msgContinuation = cont
        return stream
    }

    // MARK: - Private

    private func secondsSinceLastPong() -> TimeInterval {
        Date().timeIntervalSince(lastPongReceived)
    }

    private func sendPingIfAlive() {
        guard connection != nil else { return }
        try? sendRaw(["type": "ping"])
    }

    private func heartbeatTimeout() {
        msgContinuation?.finish(throwing: BigBroError.networkError)
        msgContinuation = nil
        stopHeartbeat()
        connection?.cancel()
        connection = nil
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func handleViability(_ isViable: Bool) {
        // Yield internal signal to BigBroClient for three-state UI
        msgContinuation?.yield(["type": isViable ? "_connected" : "_reconnecting"])
    }

    private func sendRaw(_ message: [String: Any]) throws {
        guard let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: message) else {
            print("[PeerConnection] sendRaw: failed to serialize or no connection")
            throw BigBroError.networkError
        }
        conn.send(content: framed(data), completion: .contentProcessed { error in
            if let error { print("[PeerConnection] send error: \(error)") }
        })
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectContinuation?.resume()
            connectContinuation = nil
        case .failed(let error):
            print("[PeerConnection] Connection failed: \(error)")
            stopHeartbeat()
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            helloAckContinuation?.resume(throwing: error)
            helloAckContinuation = nil
            msgContinuation?.finish(throwing: error)
            msgContinuation = nil
        case .cancelled:
            print("[PeerConnection] Connection cancelled")
            stopHeartbeat()
            connectContinuation?.resume(throwing: BigBroError.networkError)
            connectContinuation = nil
            helloAckContinuation?.resume(returning: false)
            helloAckContinuation = nil
            msgContinuation?.finish()
            msgContinuation = nil
        default:
            break
        }
    }

    private func readLoop() async {
        print("[PeerConnection] Read loop started")
        var buffer = Data()
        while let chunk = await receiveData() {
            buffer.append(chunk)
            while buffer.count >= 4 {
                let length = buffer.prefix(4).withUnsafeBytes {
                    Int(UInt32(bigEndian: $0.load(as: UInt32.self)))
                }
                guard buffer.count >= 4 + length else { break }
                let msgData = buffer[4..<(4 + length)]
                buffer = Data(buffer[(4 + length)...])
                if let json = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] {
                    print("[PeerConnection] ← type=\(json["type"] ?? "?")")
                    dispatch(json)
                } else {
                    print("[PeerConnection] Failed to parse message (\(length) bytes)")
                }
            }
        }
        print("[PeerConnection] Read loop ended")
        msgContinuation?.finish()
        msgContinuation = nil
    }

    private func dispatch(_ msg: [String: Any]) {
        let type = msg["type"] as? String
        if type == "helloAck" {
            let approved = msg["status"] as? String == "approved"
            print("[PeerConnection] dispatch: helloAck approved=\(approved)")
            helloAckContinuation?.resume(returning: approved)
            helloAckContinuation = nil
        } else if type == "pong" {
            print("[PeerConnection] pong received")
            lastPongReceived = Date()
        } else if type == "bye" {
            print("[PeerConnection] bye received, closing cleanly")
            stopHeartbeat()
            msgContinuation?.finish()
            msgContinuation = nil
        } else {
            print("[PeerConnection] dispatch: forwarding \(type ?? "?") to message stream")
            msgContinuation?.yield(msg)
        }
    }

    private func receiveData() async -> Data? {
        guard let conn = connection else {
            print("[PeerConnection] receiveData: no connection")
            return nil
        }
        return await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { print("[PeerConnection] receive error: \(error)") }
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func framed(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        return frame
    }
}
