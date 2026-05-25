import AppKit

/// Single source of truth for every app-level menu shortcut Gastty owns.
///
/// AppDelegate builds the menu from this registry instead of hard-coding
/// `keyEquivalent` strings inline, so the same data drives:
///   - The actual menu items at runtime
///   - The Settings → Keyboard pane (lets users remap)
///   - The conflict detector (cross-references against NSUserKeyEquivalents)
///
/// User overrides live in `UserDefaults` under `GasttyShortcutOverrides`
/// as a `[String: ShortcutBinding]` keyed by the registry entry's
/// stable `id` (e.g. `"quickConnect"`). System-level shortcuts (Quit,
/// Hide, Copy/Paste, tab-switch ⌘1-9, settings ⌘,) intentionally aren't
/// in the registry — those are macOS conventions we don't want users to
/// be able to reassign and break muscle memory across the OS.

// MARK: - Modifiers

/// Subset of NSEvent.ModifierFlags that we let users assign — capslock
/// and function key intentionally excluded. Mirrors the standard
/// command/shift/option/control set every macOS app uses.
struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift   = ShortcutModifiers(rawValue: 1 << 1)
    static let option  = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    /// Convert from AppKit's modifier mask. Filters down to the four
    /// modifiers we represent and drops everything else (function,
    /// caps lock, numpad-pad).
    init(eventFlags: NSEvent.ModifierFlags) {
        var s = ShortcutModifiers()
        if eventFlags.contains(.command) { s.insert(.command) }
        if eventFlags.contains(.shift)   { s.insert(.shift) }
        if eventFlags.contains(.option)  { s.insert(.option) }
        if eventFlags.contains(.control) { s.insert(.control) }
        self = s
    }

    /// Project back to AppKit's mask for assigning to NSMenuItem.
    var eventFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.command) { f.insert(.command) }
        if contains(.shift)   { f.insert(.shift) }
        if contains(.option)  { f.insert(.option) }
        if contains(.control) { f.insert(.control) }
        return f
    }

    /// "⇧⌥⌘" style display string. Order matches the macOS convention
    /// shown in menu items: Ctrl, Opt, Shift, Cmd.
    var displayString: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

// MARK: - Binding

/// A specific key combo. The `key` is the character that should appear
/// in `NSMenuItem.keyEquivalent` — lowercase ASCII for letters, "1"-"9"
/// for digits, or a single character for symbols. Empty string means
/// "unbound" (no shortcut active for this action).
struct ShortcutBinding: Codable, Hashable {
    var key: String
    var mods: ShortcutModifiers

    static let unbound = ShortcutBinding(key: "", mods: [])

    var isBound: Bool { !key.isEmpty }

    /// Human-readable form, e.g. "⌘K", "⇧⌘D", or "—" when unbound.
    var displayString: String {
        guard isBound else { return "—" }
        return mods.displayString + key.uppercased()
    }
}

// MARK: - Entry

/// One row in the registry — a user-facing action with a default
/// binding the user can override. `id` is the stable identifier used
/// in persistence; it never changes even when the menu title is
/// reworded.
struct ShortcutEntry: Identifiable {
    let id: String
    let menuTitle: String
    let `default`: ShortcutBinding
    /// Section header in the Settings pane — keeps related actions
    /// grouped (Tabs & Windows, Connections, View, etc.).
    let category: String
}

// MARK: - Registry

/// Lives for the app's lifetime. Maintains the default registry plus
/// user overrides, persists overrides to `UserDefaults`, and notifies
/// observers via `Self.changedNotification` when anything changes so
/// AppDelegate can rebuild the menu.
final class ShortcutRegistry {

    static let shared = ShortcutRegistry()

    /// Posted whenever an override is set or cleared. AppDelegate
    /// listens and rebuilds the main menu in response.
    static let changedNotification = Notification.Name("ShortcutRegistry.changed")

    /// Stable, ordered list of every shortcut we let users rebind.
    /// Adding a new menu item? Add it here too and pull its binding
    /// via `binding(for:)` when building the menu.
    let entries: [ShortcutEntry] = [
        .init(id: "newWindow",        menuTitle: "New Window",
              default: .init(key: "n", mods: [.command]),
              category: "Tabs & Windows"),
        .init(id: "newTab",           menuTitle: "New Tab",
              default: .init(key: "t", mods: [.command]),
              category: "Tabs & Windows"),
        .init(id: "closeActive",      menuTitle: "Close",
              default: .init(key: "w", mods: [.command]),
              category: "Tabs & Windows"),

        .init(id: "quickConnect",     menuTitle: "Quick Connect…",
              default: .init(key: "k", mods: [.command]),
              category: "Connections"),
        .init(id: "toggleSidebar",    menuTitle: "Toggle Connections Sidebar",
              default: .init(key: "s", mods: [.command]),
              category: "Connections"),
        .init(id: "openConnections",  menuTitle: "Connections…",
              default: .unbound,
              category: "Connections"),

        .init(id: "zoomIn",           menuTitle: "Zoom In",
              default: .init(key: "+", mods: [.command]),
              category: "View"),
        .init(id: "zoomOut",          menuTitle: "Zoom Out",
              default: .init(key: "-", mods: [.command]),
              category: "View"),
        .init(id: "zoomReset",        menuTitle: "Actual Size",
              default: .init(key: "0", mods: [.command]),
              category: "View"),
    ]

    /// Override map keyed by entry id. Empty by default.
    private var overrides: [String: ShortcutBinding] = [:]

    private let defaultsKey = "GasttyShortcutOverrides"

    private init() {
        loadOverrides()
    }

    // MARK: Lookup

    func entry(for id: String) -> ShortcutEntry? {
        entries.first(where: { $0.id == id })
    }

    /// The binding actually in effect for `id` — override if set,
    /// otherwise the default.
    func binding(for id: String) -> ShortcutBinding {
        if let override = overrides[id] { return override }
        return entry(for: id)?.default ?? .unbound
    }

    /// True when the binding for `id` differs from its default.
    func isOverridden(_ id: String) -> Bool {
        guard let override = overrides[id] else { return false }
        return override != (entry(for: id)?.default ?? .unbound)
    }

    // MARK: Mutation

    /// Assign a new binding to `id`. Pass `.unbound` to clear the
    /// shortcut entirely. The override survives if it equals the
    /// default — we treat "user set it to exactly the default" as a
    /// no-op rather than a meaningful override so resetting all
    /// overrides has the same effect as deleting them.
    func setBinding(_ binding: ShortcutBinding, for id: String) {
        if let entry = entry(for: id), binding == entry.default {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = binding
        }
        saveOverrides()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    /// Wipe a single override, returning to the default binding.
    func resetBinding(for id: String) {
        guard overrides.removeValue(forKey: id) != nil else { return }
        saveOverrides()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    /// Wipe every override at once — used by the "Restore Defaults"
    /// button in the Settings pane.
    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides.removeAll()
        saveOverrides()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    // MARK: Persistence

    private func loadOverrides() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            return
        }
        overrides = decoded
    }

    private func saveOverrides() {
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
