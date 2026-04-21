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
