import Foundation

public struct Message: @unchecked Sendable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system
        case tool
    }

    public let role: Role
    public let content: String
    public let images: [Data]?
    public let toolCalls: [[String: Any]]?
    public let toolName: String?
    public let thinking: String?

    public init(
        role: Role,
        content: String,
        images: [Data]? = nil,
        toolCalls: [[String: Any]]? = nil,
        toolName: String? = nil,
        thinking: String? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.thinking = thinking
    }

    // MARK: - Factory helpers

    public static func user(_ content: String, images: [Data] = []) -> Message {
        Message(role: .user, content: content, images: images.isEmpty ? nil : images)
    }

    public static func assistant(_ content: String) -> Message {
        Message(role: .assistant, content: content)
    }

    public static func system(_ content: String) -> Message {
        Message(role: .system, content: content)
    }

    public static func tool(name: String, content: String) -> Message {
        Message(role: .tool, content: content, toolName: name)
    }

    // MARK: - Serialization

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["role": role.rawValue, "content": content]
        if let images, !images.isEmpty {
            d["images"] = images.map { $0.base64EncodedString() }
        }
        if let toolCalls {
            d["tool_calls"] = toolCalls
        }
        if let toolName {
            d["tool_name"] = toolName
        }
        if let thinking {
            d["thinking"] = thinking
        }
        return d
    }
}
