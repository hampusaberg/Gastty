import AppKit
import Foundation

/// Process-wide store of saved connections + per-workspace folders.
///
/// Storage layout (v3):
///   - `~/Library/Application Support/<bundle>/connections.json` — the
///     single global list of `SavedConnection` records. Connection
///     fields (name, host, jumphost, etc.) live here exactly once,
///     even when a connection is reused across multiple workspaces.
///   - `~/Library/Application Support/<bundle>/workspaces/<id>/connections.json`
///     — per workspace: `{ folders, refs }`. Folders are workspace-local
///     (a "Servers" folder in Work is distinct from one in Personal).
///     `refs` is the ordered list of which connections appear in this
///     workspace and, for each, which folder it sits in (or nil for
///     root). A single connection can have refs in many workspaces.
///
/// Migration: existing v2 layout stored `{ folders, connections }` per
/// workspace with no global file. On first launch with v3 code,
/// `migrateIfNeeded` collects all per-workspace connections into the new
/// global file and rewrites each workspace's `connections.json` as
/// `{ folders, refs }` derived from the old `folderID` on each
/// connection. Pre-workspace users go through the workspace migration
/// first (`WorkspaceStore` bootstrap), then this one.
///
/// Notifications: `.connectionsDidChange` fires on any mutation so the
/// sidebar, Quick Connect, and Connections settings refresh.
final class ConnectionStore {
    static let shared = ConnectionStore()

    static let changedNotification = Notification.Name("TerminalConnectionsDidChange")

    // MARK: - Global state

    /// Every saved connection that exists anywhere, identified by
    /// `SavedConnection.id`. Reused across workspaces (one record, many
    /// references).
    private(set) var allConnections: [SavedConnection] = []

    // MARK: - Per-workspace state

    /// Folders in each workspace, keyed by workspace ID. Each
    /// workspace's value is the ordered folder list for that
    /// workspace.
    private var foldersByWorkspace: [UUID: [ConnectionFolder]] = [:]

    /// Connection refs in each workspace, keyed by workspace ID. The
    /// order of refs within a workspace defines display order in that
    /// workspace.
    private var refsByWorkspace: [UUID: [WorkspaceConnectionRef]] = [:]

    // MARK: - Convenience accessors for the active workspace

    /// All folders in the active workspace, in display order (flat).
    var folders: [ConnectionFolder] {
        foldersByWorkspace[WorkspaceStore.shared.activeID] ?? []
    }

    /// Top-level folders in the active workspace (parentID == nil).
    var topLevelFolders: [ConnectionFolder] {
        folders.filter { $0.parentID == nil }
    }

    /// Direct sub-folders of `parentID` in the active workspace.
    func subFolders(of parentID: UUID) -> [ConnectionFolder] {
        folders.filter { $0.parentID == parentID }
    }

    /// True if `folderID` is an ancestor of `targetID` in `folders`.
    /// Used to prevent cycles when nesting folders.
    func wouldCreateCycle(moving folderID: UUID, into targetID: UUID?) -> Bool {
        guard let targetID else { return false }
        var current: UUID? = targetID
        while let cur = current {
            if cur == folderID { return true }
            current = folders.first(where: { $0.id == cur })?.parentID
        }
        return false
    }

    /// Connections in the active workspace, in display order. Used by
    /// the sidebar and Quick Connect. (Settings can now also surface
    /// `allConnections` for cross-workspace management.)
    var connections: [SavedConnection] {
        let refs = refsByWorkspace[WorkspaceStore.shared.activeID] ?? []
        return refs.compactMap { ref in
            allConnections.first(where: { $0.id == ref.connectionID })
        }
    }

    /// Active-workspace connections that aren't placed in any folder.
    var rootConnections: [SavedConnection] {
        let refs = refsByWorkspace[WorkspaceStore.shared.activeID] ?? []
        return refs
            .filter { $0.folderID == nil }
            .compactMap { ref in allConnections.first(where: { $0.id == ref.connectionID }) }
    }

    /// Active-workspace connections placed in the given folder.
    func connections(in folderID: UUID) -> [SavedConnection] {
        let refs = refsByWorkspace[WorkspaceStore.shared.activeID] ?? []
        return refs
            .filter { $0.folderID == folderID }
            .compactMap { ref in allConnections.first(where: { $0.id == ref.connectionID }) }
    }

    func folder(with id: UUID) -> ConnectionFolder? {
        folders.first(where: { $0.id == id })
    }

    /// Substring filter across name / host / user, scoped to the active
    /// workspace. Used by Quick Connect.
    func filtered(by query: String) -> [SavedConnection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = connections
        if q.isEmpty { return base }
        return base.filter { c in
            c.name.lowercased().contains(q) ||
            c.host.lowercased().contains(q) ||
            c.user.lowercased().contains(q)
        }
    }

    // MARK: - Cross-workspace queries (for Settings UI)

    /// The set of workspace IDs this connection appears in. Computed by
    /// scanning the per-workspace refs — there's no denormalised list on
    /// the connection itself so this can never drift out of sync.
    func workspaces(for connectionID: UUID) -> Set<UUID> {
        var out: Set<UUID> = []
        for (wsID, refs) in refsByWorkspace where refs.contains(where: { $0.connectionID == connectionID }) {
            out.insert(wsID)
        }
        return out
    }

    // MARK: - Mutations

    /// Add a brand-new connection. By default it goes into the active
    /// workspace at the root; pass `toWorkspaces` to opt the new
    /// connection into additional workspaces at the same time.
    func add(_ connection: SavedConnection,
             toWorkspaces: Set<UUID>? = nil) {
        var record = connection
        record.folderID = nil  // legacy field — placement lives in refs
        allConnections.append(record)

        let targets = toWorkspaces ?? [WorkspaceStore.shared.activeID]
        for wsID in targets {
            var refs = refsByWorkspace[wsID] ?? []
            refs.append(WorkspaceConnectionRef(connectionID: record.id, folderID: nil))
            refsByWorkspace[wsID] = refs
            saveWorkspace(wsID)
        }
        saveGlobal()
        notify()
    }

    /// Update the editable fields on a connection. Workspace membership
    /// is NOT changed here — use `setWorkspaces(_:for:)` for that.
    func update(_ connection: SavedConnection) {
        guard let idx = allConnections.firstIndex(where: { $0.id == connection.id }) else { return }
        var record = connection
        record.folderID = nil
        allConnections[idx] = record
        saveGlobal()
        notify()
    }

    /// Remove a connection from the active workspace. If after the
    /// removal it isn't a member of any workspace, also delete the
    /// global record. (Use `removeFromAllWorkspaces` to skip the
    /// per-workspace nuance and delete everywhere unconditionally.)
    func remove(_ connection: SavedConnection) {
        let activeID = WorkspaceStore.shared.activeID
        var refs = refsByWorkspace[activeID] ?? []
        refs.removeAll { $0.connectionID == connection.id }
        refsByWorkspace[activeID] = refs
        saveWorkspace(activeID)

        if workspaces(for: connection.id).isEmpty {
            allConnections.removeAll { $0.id == connection.id }
            saveGlobal()
        }
        notify()
    }

    /// Remove the connection from every workspace it belongs to AND
    /// from the global list. Used by the Connections settings when the
    /// user explicitly deletes a connection.
    func removeFromAllWorkspaces(_ connection: SavedConnection) {
        for wsID in refsByWorkspace.keys {
            if var refs = refsByWorkspace[wsID], refs.contains(where: { $0.connectionID == connection.id }) {
                refs.removeAll { $0.connectionID == connection.id }
                refsByWorkspace[wsID] = refs
                saveWorkspace(wsID)
            }
        }
        allConnections.removeAll { $0.id == connection.id }
        saveGlobal()
        notify()
    }

    /// Move a connection within the active workspace to `folder` (or
    /// to the root when nil), placed at `index` within that group.
    func moveConnection(_ connectionID: UUID,
                        toFolder folder: UUID?,
                        at index: Int) {
        let wsID = WorkspaceStore.shared.activeID
        var refs = refsByWorkspace[wsID] ?? []
        guard let currentIdx = refs.firstIndex(where: { $0.connectionID == connectionID }) else { return }
        var moved = refs.remove(at: currentIdx)
        moved.folderID = folder

        // Translate the per-group index into an absolute index in the
        // flat refs array. Walk through siblings in the target group
        // and stop after `index` of them.
        var seen = 0
        var insertion = refs.count
        for (i, r) in refs.enumerated() where r.folderID == folder {
            if seen == index { insertion = i; break }
            seen += 1
        }
        refs.insert(moved, at: insertion)
        refsByWorkspace[wsID] = refs
        saveWorkspace(wsID)
        notify()
    }

    /// Add or remove workspace memberships for a connection so its set
    /// of workspaces exactly matches `targetIDs`. Adds go in at the
    /// root of each new workspace; removes drop the ref from each
    /// removed workspace.
    func setWorkspaces(_ targetIDs: Set<UUID>, for connectionID: UUID) {
        let current = workspaces(for: connectionID)
        let toAdd = targetIDs.subtracting(current)
        let toRemove = current.subtracting(targetIDs)

        for wsID in toAdd {
            var refs = refsByWorkspace[wsID] ?? []
            refs.append(WorkspaceConnectionRef(connectionID: connectionID, folderID: nil))
            refsByWorkspace[wsID] = refs
            saveWorkspace(wsID)
        }
        for wsID in toRemove {
            var refs = refsByWorkspace[wsID] ?? []
            refs.removeAll { $0.connectionID == connectionID }
            refsByWorkspace[wsID] = refs
            saveWorkspace(wsID)
        }
        notify()
    }

    // MARK: - Folder mutations (active workspace)

    @discardableResult
    func addFolder(name: String, parentID: UUID? = nil) -> ConnectionFolder {
        let folder = ConnectionFolder(name: name, parentID: parentID)
        let wsID = WorkspaceStore.shared.activeID
        var folders = foldersByWorkspace[wsID] ?? []
        folders.append(folder)
        foldersByWorkspace[wsID] = folders
        saveWorkspace(wsID)
        notify()
        return folder
    }

    func renameFolder(_ folderID: UUID, to name: String) {
        let wsID = WorkspaceStore.shared.activeID
        guard var folders = foldersByWorkspace[wsID],
              let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[idx].name = name
        foldersByWorkspace[wsID] = folders
        saveWorkspace(wsID)
        notify()
    }

    func removeFolder(_ folderID: UUID) {
        let wsID = WorkspaceStore.shared.activeID
        let newParent = foldersByWorkspace[wsID]?.first(where: { $0.id == folderID })?.parentID
        if var folders = foldersByWorkspace[wsID] {
            // Re-parent direct sub-folders to the deleted folder's parent.
            for i in folders.indices where folders[i].parentID == folderID {
                folders[i].parentID = newParent
            }
            folders.removeAll { $0.id == folderID }
            foldersByWorkspace[wsID] = folders
        }
        if var refs = refsByWorkspace[wsID] {
            // Move connections in this folder up to the parent (or root).
            for i in refs.indices where refs[i].folderID == folderID {
                refs[i].folderID = newParent
            }
            refsByWorkspace[wsID] = refs
        }
        saveWorkspace(wsID)
        notify()
    }

    func moveFolder(_ folderID: UUID, toParent parentID: UUID?, at index: Int) {
        let wsID = WorkspaceStore.shared.activeID
        guard var folders = foldersByWorkspace[wsID],
              let currentIdx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        // Refuse to create a cycle (e.g. dragging a folder into its own sub-folder).
        if wouldCreateCycle(moving: folderID, into: parentID) { return }
        var folder = folders.remove(at: currentIdx)
        folder.parentID = parentID
        // Find insertion point among siblings with the new parentID.
        var seen = 0
        var insertion = folders.count
        for (i, f) in folders.enumerated() where f.parentID == parentID {
            if seen == index { insertion = i; break }
            seen += 1
        }
        folders.insert(folder, at: insertion)
        foldersByWorkspace[wsID] = folders
        saveWorkspace(wsID)
        notify()
    }

    // MARK: - Init

    private init() {
        loadAll()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeWorkspaceDidSwitch(_:)),
            name: WorkspaceStore.didSwitch,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspacesDidChange(_:)),
            name: WorkspaceStore.didChange,
            object: nil
        )
    }

    @objc private func activeWorkspaceDidSwitch(_ note: Notification) {
        // The active workspace's data is already in memory — switching
        // just changes which slice the `connections` / `folders`
        // getters return. Fire the change notification so views
        // refresh.
        notify()
    }

    @objc private func workspacesDidChange(_ note: Notification) {
        // A workspace was added or removed. If added, prepare empty
        // refs/folders so saves don't no-op. If removed, drop its
        // data (the workspace's folder on disk was already cleaned up
        // by `WorkspaceStore`).
        let known = Set(WorkspaceStore.shared.workspaces.map { $0.id })
        for wsID in known where refsByWorkspace[wsID] == nil {
            refsByWorkspace[wsID] = []
            foldersByWorkspace[wsID] = []
        }
        for wsID in refsByWorkspace.keys where !known.contains(wsID) {
            refsByWorkspace[wsID] = nil
            foldersByWorkspace[wsID] = nil
        }
        notify()
    }

    // MARK: - Load / save

    /// On startup, run the v2 → v3 migration if any workspace still has
    /// an old-format file, then load both the global connections list
    /// and every workspace's refs/folders into memory.
    private func loadAll() {
        migrateIfNeeded()
        loadGlobal()
        for ws in WorkspaceStore.shared.workspaces {
            loadWorkspace(ws.id)
        }
    }

    private func loadGlobal() {
        guard let url = globalURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(GlobalConnectionsFile.self, from: data) else {
            return
        }
        allConnections = payload.connections
    }

    private func loadWorkspace(_ id: UUID) {
        guard let url = workspaceURL(id),
              let data = try? Data(contentsOf: url) else {
            foldersByWorkspace[id] = []
            refsByWorkspace[id] = []
            return
        }
        if let v3 = try? JSONDecoder().decode(WorkspaceConnectionsFileV3.self, from: data) {
            foldersByWorkspace[id] = v3.folders
            refsByWorkspace[id] = v3.refs
            return
        }
        // Fallback: file is still in v2 format (migration didn't fully
        // complete for this workspace — e.g. we crashed between
        // writing global and per-workspace files). Decode as v2 in
        // place, harvest any missing connection records into the
        // global list, and rewrite as v3.
        if let v2 = try? JSONDecoder().decode(WorkspaceConnectionsFileV2.self, from: data) {
            foldersByWorkspace[id] = v2.folders
            var refs: [WorkspaceConnectionRef] = []
            for var conn in v2.connections {
                let folder = conn.folderID
                conn.folderID = nil
                if !allConnections.contains(where: { $0.id == conn.id }) {
                    allConnections.append(conn)
                }
                refs.append(WorkspaceConnectionRef(connectionID: conn.id, folderID: folder))
            }
            refsByWorkspace[id] = refs
            saveWorkspace(id)
            saveGlobal()
            return
        }
        foldersByWorkspace[id] = []
        refsByWorkspace[id] = []
    }

    private func saveGlobal() {
        guard let url = globalURL() else { return }
        let payload = GlobalConnectionsFile(version: 1, connections: allConnections)
        write(payload, to: url)
    }

    private func saveWorkspace(_ id: UUID) {
        guard let url = workspaceURL(id) else { return }
        let payload = WorkspaceConnectionsFileV3(
            version: 3,
            folders: foldersByWorkspace[id] ?? [],
            refs: refsByWorkspace[id] ?? []
        )
        write(payload, to: url)
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    // MARK: - File shapes

    private struct GlobalConnectionsFile: Codable {
        var version: Int
        var connections: [SavedConnection]
    }

    private struct WorkspaceConnectionsFileV3: Codable {
        var version: Int
        var folders: [ConnectionFolder]
        var refs: [WorkspaceConnectionRef]
    }

    /// v2 shape — pre-cross-workspace. Read once during migration.
    private struct WorkspaceConnectionsFileV2: Codable {
        var version: Int
        var folders: [ConnectionFolder]
        var connections: [SavedConnection]
    }

    // MARK: - Paths

    private static func supportDir() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hampusaberg.Gastty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func globalURL() -> URL? {
        Self.supportDir()?.appendingPathComponent("connections.json")
    }

    private func workspaceURL(_ id: UUID) -> URL? {
        guard let base = Self.supportDir() else { return nil }
        let dir = base
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }

    private func write<T: Codable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Migration

    /// One-shot v2 → v3 migration. Detected by the absence of the
    /// global connections.json: in v2 there was no global file, in v3
    /// it always exists (even if it only contains an empty array). If
    /// the global file exists we're already on v3 and skip.
    private func migrateIfNeeded() {
        guard let global = globalURL() else { return }
        if FileManager.default.fileExists(atPath: global.path) { return }

        let fm = FileManager.default
        var migratedConnections: [SavedConnection] = []
        var migratedRefs: [UUID: [WorkspaceConnectionRef]] = [:]
        var migratedFolders: [UUID: [ConnectionFolder]] = [:]

        for ws in WorkspaceStore.shared.workspaces {
            guard let url = workspaceURL(ws.id),
                  fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { continue }
            // v2 files have `connections: [SavedConnection]`. v3 files
            // have `refs: [WorkspaceConnectionRef]`. If the v2 decode
            // fails (already v3 or empty), skip.
            guard let v2 = try? JSONDecoder().decode(WorkspaceConnectionsFileV2.self, from: data),
                  v2.version <= 2 else { continue }

            var workspaceRefs: [WorkspaceConnectionRef] = []
            for var conn in v2.connections {
                let folder = conn.folderID
                conn.folderID = nil
                migratedConnections.append(conn)
                workspaceRefs.append(WorkspaceConnectionRef(connectionID: conn.id,
                                                             folderID: folder))
            }
            migratedFolders[ws.id] = v2.folders
            migratedRefs[ws.id] = workspaceRefs
        }

        // Write global FIRST. The presence of the global file is what
        // gates re-running migration; if we crash between writes, the
        // global already-exists guard kicks in next launch and
        // `loadWorkspace` falls back to v2 for any per-workspace file
        // still in the old format (see fallback in `loadWorkspace`).
        let payload = GlobalConnectionsFile(version: 1, connections: migratedConnections)
        write(payload, to: global)

        // Now overwrite each workspace's file in v3 format.
        for ws in WorkspaceStore.shared.workspaces {
            if let url = workspaceURL(ws.id) {
                let v3 = WorkspaceConnectionsFileV3(
                    version: 3,
                    folders: migratedFolders[ws.id] ?? [],
                    refs: migratedRefs[ws.id] ?? []
                )
                write(v3, to: url)
            }
        }
    }
}
