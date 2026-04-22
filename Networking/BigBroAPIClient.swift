import Foundation

struct BigBroAPIClient {
    let device: BigBroDevice

    private var baseURL: URL {
        URL(string: "http://\(device.host):\(device.port)")!
    }

    func sendPairRequest(deviceName: String, deviceId: String) async throws {
        let url = baseURL.appending(path: "/pair/request")
        print("[BigBroKit] POST \(url)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["device_name": deviceName, "device_id": deviceId])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[BigBroKit] /pair/request -> \(status): \(String(data: data, encoding: .utf8) ?? "<binary>")")
    }

    func pollPairStatus(deviceId: String) async throws -> PairStatusResponse {
        var components = URLComponents(url: baseURL.appending(path: "/pair/status"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        guard let url = components.url else { throw BigBroError.networkError }
        let request = URLRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[BigBroKit] /pair/status -> \(status): \(String(data: data, encoding: .utf8) ?? "<binary>")")
        return try JSONDecoder().decode(PairStatusResponse.self, from: data)
    }

    func chat(token: String, messages: [Message]) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(
            token: token,
            messages: messages.map { ChatRequest.Msg(role: $0.role.rawValue, content: $0.content) }
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        return response.content
    }

    /// Opens a long-lived SSE stream to the Mac used purely for presence.
    /// Returns when the server closes the stream, the connection drops, or
    /// no data arrives for 15 seconds (read-side watchdog via URLSession's
    /// `timeoutIntervalForRequest`). `onOpen` fires once the HTTP 200 response
    /// is received (stream established).
    func streamPresence(token: String, onOpen: @Sendable () -> Void) async throws {
        var components = URLComponents(url: baseURL.appending(path: "/presence"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw BigBroError.networkError }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // timeoutIntervalForRequest is reset on each received byte; if 15s pass
        // with no data from the Mac, URLSession aborts and we treat that as a
        // dead connection.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            print("[BigBroKit] /presence -> \(status)")
            throw BigBroError.networkError
        }
        onOpen()
        for try await _ in bytes.lines {
            // consume keepalives; stream ends when server closes, connection
            // drops, or the 15s read timeout fires.
        }
    }

    func chatStream(token: String, messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = ChatRequest(
                        token: token,
                        messages: messages.map { ChatRequest.Msg(role: $0.role.rawValue, content: $0.content) }
                    )
                    request.httpBody = try JSONEncoder().encode(body)
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let delta = json["delta"] as? String {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

struct PairStatusResponse: Decodable {
    let status: String
    let token: String?
}

private struct ChatRequest: Encodable {
    let token: String
    struct Msg: Encodable {
        let role: String
        let content: String
    }
    let messages: [Msg]
}

private struct ChatResponse: Decodable {
    let content: String
}
