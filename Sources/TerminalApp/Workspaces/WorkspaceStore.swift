import AppKit
import Foundation

/// Process-wide store of workspaces.
///
/// Persists as JSON at `~/Library/Application Support/<bundle>/workspaces.json`.
/// Per-workspace data (connections + session state) lives under
/// `workspaces/<uuid>/` next to that file so each workspace is a clean,
/// inspectable folder.
///
/// On first launch, if no `workspaces.json` exists, the store creates a
/// "Default" workspace and migrates any top-level `connections.json` /
/// `state.json` into it — pre-workspace users keep their data with zero
/// effort.
///
/// Posts `WorkspaceStore.didChange` on add / remove / rename / icon
/// changes; posts `WorkspaceStore.willSwitch` *before* and
/// `WorkspaceStore.didSwitch` *after* a workspace switch so listeners
/// (`ConnectionStore`, `AppDelegate`'s window restore) can save and
/// reload around the transition.
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    static let didChange = Notification.Name("TerminalWorkspacesDidChange")
    static let willSwitch = Notification.Name("TerminalWorkspaceWillSwitch")
    static let didSwitch = Notification.Name("TerminalWorkspaceDidSwitch")

    /// All workspaces in display order. Mutations preserve insertion
    /// order; reorders are explicit via `move(_:to:)`.
    private(set) var workspaces: [Workspace] = []

    /// Currently active workspace. Always non-nil — bootstrap guarantees
    /// at least the Default workspace exists.
    private(set) var activeID: UUID

    /// Convenience accessor.
    var active: Workspace {
        workspaces.first(where: { $0.id == activeID })
            ?? workspaces.first
            ?? Workspace(name: "Default",
                         iconSymbol: WorkspaceIconCatalog.defaultIcon)
    }

    private init() {
        // Bootstrap order: load workspaces.json if present, otherwise
        // create the Default workspace and try to migrate any
        // pre-workspaces data into it.
        if let loaded = Self.loadFromDisk() {
            self.workspaces = loaded.workspaces
            self.activeID = loaded.activeID
            // Belt-and-suspenders: if `activeID` doesn't match any known
            // workspace (manual JSON edit, corrupt file), fall back.
            if !workspaces.contains(where: { $0.id == activeID }),
               let first = workspaces.first {
                self.activeID = first.id
                save()
            }
        } else {
            let defaultWS = Workspace(name: "Default",
                                      iconSymbol: WorkspaceIconCatalog.defaultIcon)
            self.workspaces = [defaultWS]
            self.activeID = defaultWS.id
            Self.migrateLegacyDataIfPresent(into: defaultWS)
            save()
        }
    }

    // MARK: - Public paths

    /// Directory holding the active workspace's per-workspace files
    /// (connections.json, state.json). Callers create the directory
    /// themselves if needed.
    static func activeWorkspaceDirectory() -> URL? {
        guard let base = supportDir() else { return nil }
        let dir = base
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(shared.activeID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Mutations

    @discardableResult
    func add(name: String, iconSymbol: String) -> Workspace {
        let ws = Workspace(name: name, iconSymbol: iconSymbol)
        workspaces.append(ws)
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return ws
    }

    func rename(_ id: UUID, to name: String) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].name = name
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func setIcon(_ id: UUID, symbol: String) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].iconSymbol = symbol
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Remove a workspace and its on-disk data. The Default workspace
    /// (first in the list, never removable) is protected — calls
    /// targeting it are silently ignored. Removing the active workspace
    /// switches to the first remaining one first.
    func remove(_ id: UUID) {
        guard workspaces.count > 1,
              let idx = workspaces.firstIndex(where: { $0.id == id }),
              idx != 0 else { return }
        if activeID == id, let first = workspaces.first {
            // Switch away before deleting so the active-workspace
            // listeners aren't pointing at a directory we're about to
            // delete.
            switchTo(first.id)
        }
        workspaces.remove(at: idx)
        // Delete the on-disk folder for this workspace — best-effort, the
        // app keeps working even if the delete fails.
        if let base = Self.supportDir() {
            let dir = base
                .appendingPathComponent("workspaces", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Switch to another workspace. Listeners react in order:
    ///   1. `willSwitch` — `AppDelegate` snapshots the current window
    ///      layout into the OLD workspace's state.json.
    ///   2. `activeID` updates.
    ///   3. `didSwitch` — `ConnectionStore` reloads its data from the
    ///      NEW workspace; `AppDelegate` closes current windows and
    ///      restores the new workspace's saved tabs.
    func switchTo(_ id: UUID) {
        guard id != activeID, workspaces.contains(where: { $0.id == id }) else { return }
        NotificationCenter.default.post(name: Self.willSwitch, object: self,
                                        userInfo: ["from": activeID, "to": id])
        activeID = id
        save()
        NotificationCenter.default.post(name: Self.didSwitch, object: self,
                                        userInfo: ["to": id])
    }

    // MARK: - Persistence

    private struct PersistedRoot: Codable {
        var version: Int
        var workspaces: [Workspace]
        var activeID: UUID
    }

    private static func storeURL() -> URL? {
        supportDir()?.appendingPathComponent("workspaces.json")
    }

    private static func supportDir() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hampusaberg.Gastty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loadFromDisk() -> (workspaces: [Workspace], activeID: UUID)? {
        guard let url = storeURL(),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(PersistedRoot.self, from: data),
              !root.workspaces.isEmpty else { return nil }
        return (root.workspaces, root.activeID)
    }

    private func save() {
        guard let url = Self.storeURL() else { return }
        let payload = PersistedRoot(version: 1,
                                    workspaces: workspaces,
                                    activeID: activeID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// One-shot migration: if the user has connections.json / state.json
    /// at the top level of the support directory (from before
    /// workspaces existed), move them into the Default workspace's
    /// folder so the user's data follows them.
    private static func migrateLegacyDataIfPresent(into defaultWS: Workspace) {
        guard let base = supportDir() else { return }
        let fm = FileManager.default
        let workspaceDir = base
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(defaultWS.id.uuidString, isDirectory: true)
        try? fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        for filename in ["connections.json", "state.json"] {
            let old = base.appendingPathComponent(filename)
            let new = workspaceDir.appendingPathComponent(filename)
            guard fm.fileExists(atPath: old.path),
                  !fm.fileExists(atPath: new.path) else { continue }
            try? fm.moveItem(at: old, to: new)
        }
    }
}
