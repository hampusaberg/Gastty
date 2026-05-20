import AppKit
import Foundation

/// Process-wide store of saved connections.
///
/// Persists as JSON to `~/Library/Application Support/<bundle-id>/connections.json`.
/// Posts `.connectionsDidChange` on every mutation so the Connections window
/// and Quick Connect palette can refresh their UI.
final class ConnectionStore {
    static let shared = ConnectionStore()

    static let changedNotification = Notification.Name("TerminalConnectionsDidChange")

    private(set) var connections: [SavedConnection] = []

    private init() {
        load()
    }

    // MARK: - Mutations

    func add(_ connection: SavedConnection) {
        connections.append(connection)
        save()
        notify()
    }

    func update(_ connection: SavedConnection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
            save()
            notify()
        }
    }

    func remove(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        save()
        notify()
    }

    func filtered(by query: String) -> [SavedConnection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return connections }
        return connections.filter { c in
            c.name.lowercased().contains(q) ||
            c.host.lowercased().contains(q) ||
            c.user.lowercased().contains(q)
        }
    }

    // MARK: - Persistence

    private func storeURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hampusaberg.Gastty"
        let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("connections.json")
    }

    private func load() {
        guard let url = storeURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return
        }
        connections = decoded
    }

    private func save() {
        guard let url = storeURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(connections) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }
}
