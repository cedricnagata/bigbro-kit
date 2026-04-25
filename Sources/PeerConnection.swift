import Foundation
import Network

actor PeerConnection {
    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var helloAckContinuation: CheckedContinuation<(approved: Bool, missingModels: [String]), Error>?
    private var msgContinuation: AsyncThrowingStream<[String: Any], Error>.Continuation?

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

    /// Send hello and wait for helloAck. Returns `(approved, missingModels)`.
    func sendHello(deviceId: String, deviceName: String, appName: String, requiredModels: [String] = []) async throws -> (approved: Bool, missingModels: [String]) {
        print("[PeerConnection] Sending hello (deviceId=\(deviceId.prefix(8)), deviceName=\(deviceName), appName=\(appName))")
        var msg: [String: Any] = ["type": "hello", "deviceId": deviceId, "deviceName": deviceName, "appName": appName]
        if !requiredModels.isEmpty { msg["requiredModels"] = requiredModels }
        try sendRaw(msg)
        print("[PeerConnection] Hello sent, waiting for helloAck")
        let result = try await withCheckedThrowingContinuation { cont in
            self.helloAckContinuation = cont
        }
        print("[PeerConnection] helloAck received: approved=\(result.approved) missing=\(result.missingModels)")
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

    func disconnect() {
        print("[PeerConnection] Disconnecting (sending bye)")
        try? sendRaw(["type": "bye"])
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
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            helloAckContinuation?.resume(throwing: error)
            helloAckContinuation = nil
            msgContinuation?.finish(throwing: error)
            msgContinuation = nil
        case .cancelled:
            print("[PeerConnection] Connection cancelled")
            connectContinuation?.resume(throwing: BigBroError.networkError)
            connectContinuation = nil
            helloAckContinuation?.resume(returning: (approved: false, missingModels: []))
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
            let missing = msg["missingModels"] as? [String] ?? []
            print("[PeerConnection] dispatch: helloAck approved=\(approved) missing=\(missing)")
            helloAckContinuation?.resume(returning: (approved: approved, missingModels: missing))
            helloAckContinuation = nil
        } else if type == "bye" {
            print("[PeerConnection] bye received, closing cleanly")
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
