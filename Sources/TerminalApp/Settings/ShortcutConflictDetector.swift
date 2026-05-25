import AppKit

/// Detects when something else on the system has claimed one of our
/// menu shortcuts, so the user gets a real diagnostic instead of
/// "⌘K doesn't do anything for me, must be broken."
///
/// Two layers of detection, because macOS exposes very different
/// amounts of information at each layer:
///
/// 1. **Exact, named conflicts** — macOS's *App Shortcuts* feature
///    (System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts)
///    stores user-set remaps in `NSUserKeyEquivalents`, keyed by menu
///    title. We can read that dict and tell the user *exactly* which
///    of their menu actions has been remapped and to what.
///
/// 2. **Behavioural, anonymous conflicts** — third-party event-tap
///    apps (Karabiner-Elements, BetterTouchTool, Raycast, Shortcat,
///    Hammerspoon) intercept keys *below* AppKit. There is no public
///    macOS API to ask "who has claimed ⌘K?" — by design. So we
///    install an `NSEvent` local monitor: when we see a Cmd-modified
///    keypress that matches a registered shortcut, we set a pending
///    flag and arm a short timer. If the matching menu action fires
///    inside that window, the flag clears and nothing happens. If it
///    doesn't, *something* swallowed the keypress and we surface a
///    "possibly Karabiner / Raycast / similar" warning.
///
/// Together: when conflict matters, the user gets enough information
/// to fix it.

// MARK: - Conflict types

enum ShortcutConflictSource: Equatable {
    /// macOS App Shortcuts override. `remappedTo` is the user's new
    /// binding, if we could parse it.
    case appShortcutsOverride(remappedTo: ShortcutBinding?)
    /// Behavioural — keypress observed but action didn't fire.
    case eventTapInterception
}

struct ShortcutConflict: Equatable {
    let entryId: String
    let menuTitle: String
    let originalBinding: ShortcutBinding
    let source: ShortcutConflictSource
}

// MARK: - Detector

final class ShortcutConflictDetector {

    /// Posted when new behavioural conflicts are detected. UI listens
    /// and shows the banner / alert. The notification's `object` is a
    /// `[ShortcutConflict]`.
    static let conflictsDetectedNotification = Notification.Name("ShortcutConflictDetector.conflictsDetected")

    private let registry: ShortcutRegistry
    private var pendingFires: [String: Date] = [:]   // entryId → keypress timestamp
    private var seenBehaviouralConflicts: Set<String> = []
    private var monitor: Any?

    /// Window during which we expect a menu action to fire after the
    /// matching keypress. AppKit's menu dispatch is essentially
    /// synchronous from the same runloop turn, so 120ms is generous.
    private let firingWindow: TimeInterval = 0.12

    init(registry: ShortcutRegistry = .shared) {
        self.registry = registry
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: Public API

    /// Scan for *exact* conflicts (App Shortcuts overrides). Cheap,
    /// purely synchronous — no UI required. Call at launch.
    func scanForKnownConflicts() -> [ShortcutConflict] {
        let overrides = readAppShortcutsOverrides()
        guard !overrides.isEmpty else { return [] }

        var conflicts: [ShortcutConflict] = []
        for entry in registry.entries {
            // Match on the user-facing menu title — that's the key
            // macOS uses in NSUserKeyEquivalents.
            guard let raw = overrides[entry.menuTitle] else { continue }
            conflicts.append(ShortcutConflict(
                entryId: entry.id,
                menuTitle: entry.menuTitle,
                originalBinding: entry.default,
                source: .appShortcutsOverride(remappedTo: Self.parseKeyEquivalent(raw))
            ))
        }
        return conflicts
    }

    /// Install the local NSEvent monitor that watches for behavioural
    /// conflicts (event-tap apps eating our keypresses). Call once at
    /// launch. The monitor stays installed for the app's lifetime.
    func startBehaviouralMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recordKeyDown(event)
            // Return the event unmodified — we only observe, never
            // consume. The menu system still gets first crack at it.
            return event
        }
        // Wrap the registry's bindings so we know when an action did
        // fire. Cleaner alternative would be method swizzling on
        // NSMenu.performActionForItemAt, but that's more invasive
        // than the value it brings; we just observe via a hook in
        // AppDelegate.
    }

    /// AppDelegate calls this from inside every shortcut-bound action
    /// handler — confirms "yes, our handler ran" so the detector
    /// doesn't flag the shortcut as swallowed.
    func noteActionFired(for entryId: String) {
        pendingFires.removeValue(forKey: entryId)
    }

    // MARK: Private — keydown bookkeeping

    private func recordKeyDown(_ event: NSEvent) {
        // We only care about Cmd-modified events — anything without
        // Cmd is normal terminal input.
        guard event.modifierFlags.contains(.command) else { return }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

        let pressed = ShortcutBinding(
            key: chars.lowercased(),
            mods: ShortcutModifiers(eventFlags: event.modifierFlags
                .intersection([.command, .shift, .option, .control]))
        )

        // Find any registered entry currently bound to this combo.
        let matches = registry.entries.filter { registry.binding(for: $0.id) == pressed }
        guard !matches.isEmpty else { return }

        let now = Date()
        for match in matches {
            pendingFires[match.id] = now
        }

        // After the firing window, anything still pending is suspect.
        DispatchQueue.main.asyncAfter(deadline: .now() + firingWindow) { [weak self] in
            self?.flushPendingConflicts(pressedAt: now)
        }
    }

    private func flushPendingConflicts(pressedAt: Date) {
        var newConflicts: [ShortcutConflict] = []
        for (entryId, ts) in pendingFires where ts == pressedAt {
            pendingFires.removeValue(forKey: entryId)
            guard !seenBehaviouralConflicts.contains(entryId) else { continue }
            seenBehaviouralConflicts.insert(entryId)
            guard let entry = registry.entry(for: entryId) else { continue }
            newConflicts.append(ShortcutConflict(
                entryId: entry.id,
                menuTitle: entry.menuTitle,
                originalBinding: entry.default,
                source: .eventTapInterception
            ))
        }
        guard !newConflicts.isEmpty else { return }
        NotificationCenter.default.post(
            name: Self.conflictsDetectedNotification,
            object: newConflicts
        )
    }

    // MARK: Private — reading NSUserKeyEquivalents

    /// Read user-set menu shortcut overrides from `NSUserKeyEquivalents`.
    /// Combines the per-app dict (keyed by our bundle ID) with the
    /// global `NSGlobalDomain` dict ("All Applications"). Per-app
    /// wins if both are set for the same title.
    ///
    /// Values look like `"@k"` (⌘K), `"@$k"` (⇧⌘K), etc. See
    /// `parseKeyEquivalent` for the encoding.
    private func readAppShortcutsOverrides() -> [String: String] {
        var combined: [String: String] = [:]

        let global = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["NSUserKeyEquivalents"]
            as? [String: String]
        if let global { combined.merge(global) { _, new in new } }

        if let bundleID = Bundle.main.bundleIdentifier {
            let perApp = UserDefaults.standard
                .persistentDomain(forName: bundleID)?["NSUserKeyEquivalents"]
                as? [String: String]
            if let perApp { combined.merge(perApp) { _, new in new } }
        }
        return combined
    }

    /// Decode the cryptic `NSUserKeyEquivalents` string format into a
    /// `ShortcutBinding`. macOS uses single-character modifier
    /// prefixes: `@` = Cmd, `~` = Option, `$` = Shift, `^` = Control.
    /// Prefixes can be combined in any order; the last char is the
    /// key. Returns nil if parsing fails (unusual encoding) — caller
    /// then just notes "remapped to something" without the specifics.
    static func parseKeyEquivalent(_ raw: String) -> ShortcutBinding? {
        guard !raw.isEmpty else { return nil }
        var mods: ShortcutModifiers = []
        var key = ""
        for ch in raw {
            switch ch {
            case "@": mods.insert(.command)
            case "~": mods.insert(.option)
            case "$": mods.insert(.shift)
            case "^": mods.insert(.control)
            default:  key.append(ch)
            }
        }
        guard key.count == 1 else { return nil }
        return ShortcutBinding(key: key.lowercased(), mods: mods)
    }
}
