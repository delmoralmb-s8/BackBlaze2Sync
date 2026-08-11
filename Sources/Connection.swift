import Foundation

/// A saved B2 destination: an rclone remote (holding the account credentials) + a bucket.
struct Connection: Codable, Identifiable, Equatable {
    var name: String
    var remoteName: String
    var bucket: String

    var id: String { name }
    var remotePrefix: String { "\(remoteName):\(bucket)/" }
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published var connections: [Connection]
    @Published var activeID: String

    static let defaultConnection = Connection(name: "Mi B2", remoteName: "b2", bucket: "nathans")

    private let connectionsKey = "b2sync.connections.v1"
    private let activeKey = "b2sync.activeConnection.v1"

    init() {
        let defaults = UserDefaults.standard
        // A saved (even empty) array means the user deliberately disconnected everything —
        // only truly missing/corrupt data falls back to the built-in default on first launch.
        let loaded: [Connection]
        if let data = defaults.data(forKey: connectionsKey),
           let decoded = try? JSONDecoder().decode([Connection].self, from: data) {
            loaded = decoded
        } else {
            loaded = [Self.defaultConnection]
        }
        connections = loaded
        activeID = defaults.string(forKey: activeKey) ?? loaded.first?.id ?? ""
    }

    var active: Connection? {
        connections.first { $0.id == activeID }
    }

    func addOrUpdate(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        activeID = connection.id
        persist()
    }

    func select(_ id: String) {
        guard connections.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    /// `id` is just the name, so renaming changes it — `activeID` gets updated too when the
    /// renamed connection was the active one, otherwise it'd silently point at nothing.
    func rename(_ id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != id,
              let index = connections.firstIndex(where: { $0.id == id }),
              !connections.contains(where: { $0.id == trimmed }) else { return }
        let wasActive = activeID == id
        connections[index].name = trimmed
        if wasActive { activeID = trimmed }
        persist()
    }

    /// Can empty out every connection — ContentView shows an empty state when `active` is nil.
    func remove(_ id: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections.remove(at: index)
        if activeID == id { activeID = connections.first?.id ?? "" }
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: connectionsKey)
        }
        defaults.set(activeID, forKey: activeKey)
    }
}
