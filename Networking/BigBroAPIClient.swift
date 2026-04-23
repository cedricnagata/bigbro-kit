import Foundation

// Internal event type used by the agentic loop in BigBroClient.
enum ChatStreamEvent {
    case delta(String)
    case toolCalls([[String: Any]])
}

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

    func chat(token: String, messages: [[String: Any]]) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["token": token, "messages": messages, "stream": false]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        return response.content
    }

    /// SSE streaming chat without tools.
    func chatStream(token: String, messages: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in chatEvents(token: token, messages: messages, tools: []) {
                        if case .delta(let text) = event { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// SSE streaming that surfaces both text deltas and tool calls.
    /// Used by BigBroClient's agentic loop when tools are provided.
    func chatEvents(token: String,
                    messages: [[String: Any]],
                    tools: [BigBroTool]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var body: [String: Any] = ["token": token, "messages": messages, "stream": true]
                    if !tools.isEmpty {
                        let toolDefs = try tools.map { tool -> Any in
                            let data = try JSONEncoder().encode(tool.definition)
                            return try JSONSerialization.jsonObject(with: data)
                        }
                        body["tools"] = toolDefs
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let delta = json["delta"] as? String {
                            continuation.yield(.delta(delta))
                        } else if let raw = json["tool_calls"],
                                  let calls = raw as? [[String: Any]] {
                            continuation.yield(.toolCalls(calls))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Long-lived SSE presence stream.
    func streamPresence(token: String, onOpen: @Sendable () -> Void) async throws {
        var components = URLComponents(url: baseURL.appending(path: "/presence"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw BigBroError.networkError }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

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
        for try await _ in bytes.lines { }
    }
}

struct PairStatusResponse: Decodable {
    let status: String
    let token: String?
}

private struct ChatResponse: Decodable {
    let content: String
}
