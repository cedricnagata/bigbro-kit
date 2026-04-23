import Foundation

public struct Message: Sendable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: String) -> Message {
        Message(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> Message {
        Message(role: .assistant, content: content)
    }

    public static func system(_ content: String) -> Message {
        Message(role: .system, content: content)
    }

    func toDict() -> [String: Any] {
        ["role": role.rawValue, "content": content]
    }
}
