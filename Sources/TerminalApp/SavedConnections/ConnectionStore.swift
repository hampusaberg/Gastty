import AppKit
import Foundation

/// Process-wide store of saved connections + folders.
///
/// Persists as JSON to `~/Library/Application Support/<bundle-id>/connections.json`.
/// Posts `.connectionsDidChange` on every mutation so the Connections window,
/// the sidebar, and the Quick Connect palette refresh their UI.
///
/// Order is significant: `folders` is in display order, and `connections`
/// holds both root-level entries and the per-folder sequence (a connection's
/// neighbours within the same folder are its siblings in array order).
final class ConnectionStore {
    static let shared = ConnectionStore()

    static let changedNotification = Notification.Name("TerminalConnectionsDidChange")

    private(set) var connections: [SavedConnection] = []
    private(set) var folders: [ConnectionFolder] = []

    private init() {
        load()
    }

    // MARK: - Connection mutations

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

    /// Move a connection into `folder` (or to the root when nil) and place it
    /// at `index` within that group's siblings. `index` is clamped.
    func moveConnection(_ connectionID: UUID, toFolder folder: UUID?, at index: Int) {
        guard let currentIdx = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        var moved = connections.remove(at: currentIdx)
        moved.folderID = folder

        // Translate the per-group index back into an absolute index in the
        // flat `connections` array. We walk through siblings in the target
        // group and stop when we've passed `index` of them.
        let absolute = absoluteInsertionIndex(forFolder: folder, groupIndex: index)
        connections.insert(moved, at: absolute)
        save()
        notify()
    }

    // MARK: - Folder mutations

    @discardableResult
    func addFolder(name: String) -> ConnectionFolder {
        let folder = ConnectionFolder(name: name)
        folders.append(folder)
        save()
        notify()
        return folder
    }

    func renameFolder(_ folderID: UUID, to name: String) {
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx].name = name
        save()
        notify()
    }

    /// Remove a folder. Connections inside the folder are moved back to the
    /// root rather than deleted.
    func removeFolder(_ folderID: UUID) {
        folders.removeAll { $0.id == folderID }
        for i in connections.indices where connections[i].folderID == folderID {
            connections[i].folderID = nil
        }
        save()
        notify()
    }

    func moveFolder(_ folderID: UUID, to index: Int) {
        guard let currentIdx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let folder = folders.remove(at: currentIdx)
        let clamped = max(0, min(folders.count, index))
        folders.insert(folder, at: clamped)
        save()
        notify()
    }

    // MARK: - Queries

    /// Connections at the root (not in any folder), in display order.
    var rootConnections: [SavedConnection] {
        connections.filter { $0.folderID == nil }
    }

    func connections(in folderID: UUID) -> [SavedConnection] {
        connections.filter { $0.folderID == folderID }
    }

    func folder(with id: UUID) -> ConnectionFolder? {
        folders.first(where: { $0.id == id })
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

    // MARK: - Internal helpers

    /// Given a target folder and the desired index *within that folder's
    /// siblings*, return the absolute index in `connections` to insert at.
    private func absoluteInsertionIndex(forFolder folder: UUID?, groupIndex: Int) -> Int {
        var seen = 0
        for (idx, conn) in connections.enumerated() {
            if conn.folderID == folder {
                if seen == groupIndex { return idx }
                seen += 1
            }
        }
        return connections.count
    }

    // MARK: - Persistence

    /// v2 file shape — wraps both folders and connections. v1 was a bare
    /// `[SavedConnection]` array; we decode either transparently.
    private struct PersistedV2: Codable {
        var version: Int
        var folders: [ConnectionFolder]
        var connections: [SavedConnection]
    }

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
              let data = try? Data(contentsOf: url) else {
            return
        }
        let decoder = JSONDecoder()
        if let v2 = try? decoder.decode(PersistedV2.self, from: data) {
            folders = v2.folders
            connections = v2.connections
            return
        }
        // Fall back to v1 (raw array of connections, no folders yet).
        if let v1 = try? decoder.decode([SavedConnection].self, from: data) {
            connections = v1
            folders = []
        }
    }

    private func save() {
        guard let url = storeURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = PersistedV2(version: 2, folders: folders, connections: connections)
        if let data = try? encoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }
}
