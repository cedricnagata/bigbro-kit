import Foundation

public struct PairedDeviceMeta: Codable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var lastPairedAt: Date

    public init(id: String, name: String, lastPairedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.lastPairedAt = lastPairedAt
    }
}

/// UserDefaults-backed persistent record of Macs the user has previously paired
/// with. Keyed by the Bonjour service name (== Mac's localized hostname), which
/// is what's available to the iOS client at discovery time.
final class PairedDeviceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "bigbro.kit.pairedDevices"
    private let autoReconnectKey = "bigbro.kit.autoReconnectEnabled"
    private let queue = DispatchQueue(label: "bigbro.kit.PairedDeviceStore")

    init(suiteName: String? = "com.bigbro.kit") {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
    }

    func add(id: String, name: String) {
        queue.sync {
            var map = loadLocked()
            map[id] = PairedDeviceMeta(id: id, name: name, lastPairedAt: Date())
            saveLocked(map)
        }
    }

    func remove(_ id: String) {
        queue.sync {
            var map = loadLocked()
            map.removeValue(forKey: id)
            saveLocked(map)
        }
    }

    func removeAll() {
        queue.sync {
            saveLocked([:])
        }
    }

    func contains(_ id: String) -> Bool {
        queue.sync { loadLocked()[id] != nil }
    }

    func all() -> [PairedDeviceMeta] {
        queue.sync { Array(loadLocked().values) }
    }

    func ids() -> Set<String> {
        queue.sync { Set(loadLocked().keys) }
    }

    var autoReconnectEnabled: Bool {
        get { defaults.bool(forKey: autoReconnectKey) }
        set { defaults.set(newValue, forKey: autoReconnectKey) }
    }

    // MARK: - Private

    private func loadLocked() -> [String: PairedDeviceMeta] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: PairedDeviceMeta].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveLocked(_ map: [String: PairedDeviceMeta]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }
}
