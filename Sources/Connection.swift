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

    static let defaultConnection = Connection(name: "Mi B2", remoteName: "b2", bucket: "mi-bucket")

    private let connectionsKey = "b2sync.connections.v1"
    private let activeKey = "b2sync.activeConnection.v1"

    init() {
        let defaults = UserDefaults.standard
        let loaded: [Connection]
        if let data = defaults.data(forKey: connectionsKey),
           let decoded = try? JSONDecoder().decode([Connection].self, from: data),
           !decoded.isEmpty {
            loaded = decoded
        } else {
            loaded = [Self.defaultConnection]
        }
        connections = loaded
        activeID = defaults.string(forKey: activeKey) ?? loaded[0].id
    }

    var active: Connection {
        connections.first { $0.id == activeID } ?? connections[0]
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

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: connectionsKey)
        }
        defaults.set(activeID, forKey: activeKey)
    }
}
