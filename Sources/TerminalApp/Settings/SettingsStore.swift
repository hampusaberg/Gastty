import Foundation
import AppKit

/// Process-wide settings store. Persists `AppSettings` to JSON and a sibling
/// `runtime.conf` (Ghostty config syntax) that GhosttyRuntime loads.
final class SettingsStore {
    static let shared = SettingsStore()

    static let changedNotification = Notification.Name("TerminalSettingsDidChange")

    private(set) var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
    }

    private init() {
        if let url = Self.settingsURL(),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
        // Always write the runtime.conf on startup so it's there for the
        // initial GhosttyRuntime load.
        writeRuntimeConf()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    /// Absolute path to the generated `runtime.conf` file. Stable across
    /// launches — pass to `ghostty_config_load_file`.
    static func runtimeConfPath() -> String? {
        runtimeConfURL()?.path
    }

    // MARK: - Persistence

    private func save() {
        if let url = Self.settingsURL() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(settings) {
                try? data.write(to: url, options: .atomic)
            }
        }
        writeRuntimeConf()
    }

    private func writeRuntimeConf() {
        guard let url = Self.runtimeConfURL() else { return }
        try? settings.renderConfigFile().write(to: url, atomically: true, encoding: .utf8)
    }

    private static func supportDir() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hampusaberg.Gastty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func settingsURL() -> URL? {
        supportDir()?.appendingPathComponent("settings.json")
    }

    private static func runtimeConfURL() -> URL? {
        supportDir()?.appendingPathComponent("runtime.conf")
    }
}
