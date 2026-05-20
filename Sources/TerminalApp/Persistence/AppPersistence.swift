import AppKit

/// State we serialize so a quit-and-relaunch lands you back in the same
/// windows, tabs, and split layout. We can't preserve the running shells
/// themselves — they're new processes after relaunch — but we restore each
/// surface's working directory so the new shell starts where the old one
/// left off.
struct PersistedAppState: Codable {
    var windows: [PersistedWindowState]
}

struct PersistedWindowState: Codable {
    var frame: PersistedFrame?
    var sessions: [PersistedSessionState]
    var activeSessionIndex: Int
}

struct PersistedFrame: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: NSRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
    var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

struct PersistedSessionState: Codable {
    var title: String
    var titleLocked: Bool
    var root: PersistedSplitNode
}

indirect enum PersistedSplitNode: Codable {
    case leaf(workingDirectory: String?)
    case split(orientation: PersistedOrientation,
               first: PersistedSplitNode,
               second: PersistedSplitNode)
}

enum PersistedOrientation: String, Codable {
    case horizontal, vertical
}

/// File-backed store for the persisted state. JSON at
/// `~/Library/Application Support/<bundle>/state.json`.
enum AppPersistence {
    static func load() -> PersistedAppState? {
        guard let url = storeURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedAppState.self, from: data)
    }

    static func save(_ state: PersistedAppState) {
        guard let url = storeURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func storeURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hampusaberg.Gastty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }
}
