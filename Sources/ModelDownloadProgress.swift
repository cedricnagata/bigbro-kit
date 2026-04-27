import Foundation

public struct ModelDownloadProgress: Sendable, Hashable {
    public let model: String
    public var status: String          // e.g. "downloading", "verifying digest"
    public var bytesCompleted: Int64
    public var bytesTotal: Int64
    public var done: Bool
    public var success: Bool           // valid when `done == true`
    public var error: String?

    public var percent: Double {
        bytesTotal > 0 ? Double(bytesCompleted) / Double(bytesTotal) : 0
    }

    public init(model: String,
                status: String,
                bytesCompleted: Int64,
                bytesTotal: Int64,
                done: Bool,
                success: Bool,
                error: String?) {
        self.model = model
        self.status = status
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.done = done
        self.success = success
        self.error = error
    }
}
