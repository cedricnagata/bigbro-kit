import Foundation

public struct BigBroDevice: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let host: String
    public let port: Int

    public init(id: String, name: String, host: String, port: Int) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }
}
