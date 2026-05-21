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
               second: PersistedSplitNode,
               ratio: Double)

    // Hand-rolled Codable that matches Swift's auto-synthesized
    // enum-with-associated-values shape — outer container keyed by case
    // name, inner container keyed by associated-value label — so existing
    // state.json files (written before `ratio` existed) still decode.
    // The `ratio` key is decoded with `decodeIfPresent` so legacy splits
    // default to 0.5.
    private enum OuterKey: String, CodingKey { case leaf, split }
    private enum LeafKey: String, CodingKey { case workingDirectory }
    private enum SplitKey: String, CodingKey {
        case orientation, first, second, ratio
    }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKey.self)
        if outer.allKeys.contains(.leaf) {
            let inner = try outer.nestedContainer(keyedBy: LeafKey.self, forKey: .leaf)
            let wd = try inner.decodeIfPresent(String.self, forKey: .workingDirectory)
            self = .leaf(workingDirectory: wd)
        } else if outer.allKeys.contains(.split) {
            let inner = try outer.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
            let orientation = try inner.decode(PersistedOrientation.self, forKey: .orientation)
            let first = try inner.decode(PersistedSplitNode.self, forKey: .first)
            let second = try inner.decode(PersistedSplitNode.self, forKey: .second)
            let ratio = try inner.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
            self = .split(orientation: orientation,
                          first: first,
                          second: second,
                          ratio: ratio)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "PersistedSplitNode: no recognised case key"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: OuterKey.self)
        switch self {
        case .leaf(let wd):
            var inner = outer.nestedContainer(keyedBy: LeafKey.self, forKey: .leaf)
            try inner.encodeIfPresent(wd, forKey: .workingDirectory)
        case .split(let orientation, let first, let second, let ratio):
            var inner = outer.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
            try inner.encode(orientation, forKey: .orientation)
            try inner.encode(first, forKey: .first)
            try inner.encode(second, forKey: .second)
            try inner.encode(ratio, forKey: .ratio)
        }
    }
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

    /// Window/tab state lives under the active workspace's directory so
    /// each workspace remembers its own open tabs across launches AND
    /// workspace switches. `WorkspaceStore.activeWorkspaceDirectory`
    /// ensures the folder exists.
    private static func storeURL() -> URL? {
        WorkspaceStore.activeWorkspaceDirectory()?
            .appendingPathComponent("state.json")
    }
}
