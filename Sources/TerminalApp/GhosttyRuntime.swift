import Foundation
import GhosttyKit
import AppKit

/// Owns the singleton `ghostty_app_t` and the loaded config.
///
/// libghostty operates on a process-global `app` handle. Surfaces (terminals)
/// are created against it via `ghostty_surface_new`. Callbacks defined in
/// `ghostty_runtime_config_s` let libghostty notify us (need-to-tick, action,
/// clipboard, close).
final class GhosttyRuntime: ObservableObject {
    static let shared = GhosttyRuntime()

    let app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    /// All live surface hosts. Held weakly so we can broadcast config
    /// changes without retaining views past their window's lifetime.
    private var liveSurfaces: NSHashTable<SurfaceHostView> = NSHashTable.weakObjects()

    func register(surface host: SurfaceHostView) { liveSurfaces.add(host) }
    func unregister(surface host: SurfaceHostView) { liveSurfaces.remove(host) }

    private init() {
        // Initialize the global ghostty state. Must run once per process.
        let argc: UInt = 1
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("Gastty")]
        _ = argv.withUnsafeMutableBufferPointer { buf -> Int32 in
            ghostty_init(uintptr_t(argc), buf.baseAddress)
        }

        // Build a config. Order matters — later loads override earlier ones:
        //   1. bundled default.conf (our shipping defaults)
        //   2. user's ~/.config/ghostty/config (theirs trumps ours)
        //   3. our runtime.conf (Settings UI mutations always win)
        guard let cfg = Self.buildConfig() else {
            self.config = nil
            self.app = nil
            return
        }
        self.config = cfg

        // Build the runtime config. C struct → field-by-field assignment.
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                if let app = GhosttyRuntime.shared.app {
                    ghostty_app_tick(app)
                }
            }
        }
        runtime.action_cb = { _, target, action in
            // Most actions still no-op. We handle splits and goto-split so
            // the user's ⌘D / ⌘⇧D / ⌘[ / ⌘] (Ghostty's defaults) actually
            // create panes in our UI.
            guard let surfacePtr = target.target.surface else { return true }
            guard let userdata = ghostty_surface_userdata(surfacePtr) else { return true }
            let host = Unmanaged<SurfaceHostView>.fromOpaque(userdata).takeUnretainedValue()

            switch action.tag {
            case GHOSTTY_ACTION_NEW_SPLIT:
                let direction = action.action.new_split
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.performSplit(from: host, direction: direction)
                }
                return true

            case GHOSTTY_ACTION_GOTO_SPLIT:
                let target = action.action.goto_split
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.gotoSplit(from: host, target: target)
                }
                return true

            case GHOSTTY_ACTION_START_SEARCH:
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.showSearch(from: host)
                }
                return true

            case GHOSTTY_ACTION_END_SEARCH:
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.hideSearch(from: host)
                }
                return true

            case GHOSTTY_ACTION_SEARCH_TOTAL:
                let total = action.action.search_total.total
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.searchTotal(from: host, total: Int(total))
                }
                return true

            case GHOSTTY_ACTION_SEARCH_SELECTED:
                let selected = action.action.search_selected.selected
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.searchSelected(from: host, index: Int(selected))
                }
                return true

            case GHOSTTY_ACTION_PWD:
                // OSC 7 (or shell integration) reports a directory change.
                // We capture per-surface so session restore can start the
                // new shell in the same directory after relaunch.
                guard let pwdPtr = action.action.pwd.pwd else { return true }
                let pwd = String(cString: pwdPtr)
                DispatchQueue.main.async { host.workingDirectory = pwd }
                return true

            case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
                // Shells fire this via OSC 0/2 ("vim" sets the title to the
                // filename, ssh to "user@host: ~", zsh themes to the cwd…)
                // Both action variants have the same payload struct.
                let titlePtr = (action.tag == GHOSTTY_ACTION_SET_TAB_TITLE)
                    ? action.action.set_tab_title.title
                    : action.action.set_title.title
                guard let titlePtr else { return true }
                let newTitle = String(cString: titlePtr)
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.updateTitle(from: host, to: newTitle)
                }
                return true

            default:
                return true
            }
        }
        runtime.read_clipboard_cb = { userdata, _, state in
            // userdata is the SurfaceHostView pointer we set on surface
            // creation. Pull the bound surface_t off it and complete the
            // request synchronously with whatever's on the system clipboard.
            guard let userdata,
                  let str = NSPasteboard.general.string(forType: .string) else {
                return false
            }
            let host = Unmanaged<SurfaceHostView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = host.surface else { return false }
            str.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, len, _ in
            // content is an array of {mime, data} structs of length `len`.
            // We only honor text/plain — image/file URLs are out of scope.
            guard let content, len > 0 else { return }
            for i in 0..<len {
                let entry = content[i]
                guard let mimePtr = entry.mime,
                      let dataPtr = entry.data else { continue }
                let mime = String(cString: mimePtr)
                guard mime == "text/plain" else { continue }
                let str = String(cString: dataPtr)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
                return
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            // Process exited inside this pane. Hop to main, remove the
            // leaf from its session's tree; tab/window may also close.
            guard let userdata else { return }
            let host = Unmanaged<SurfaceHostView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                GhosttyRuntime.shared.handleSurfaceClose(host)
            }
        }

        self.app = withUnsafePointer(to: &runtime) { rtPtr in
            ghostty_app_new(rtPtr, cfg)
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    /// Build a fresh `ghostty_config_t` from disk. Caller owns the returned
    /// pointer (we hand it off to libghostty which will free it).
    private static func buildConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        if let defaults = Bundle.main.path(forResource: "default", ofType: "conf") {
            ghostty_config_load_file(cfg, defaults)
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        if let runtimePath = SettingsStore.runtimeConfPath(),
           FileManager.default.fileExists(atPath: runtimePath) {
            ghostty_config_load_file(cfg, runtimePath)
        }
        ghostty_config_finalize(cfg)
        return cfg
    }

    // MARK: - Split & close routing

    /// Find the TerminalWindowController that owns the session containing
    /// `host`. We look it up via the AppDelegate's controller list rather
    /// than walking up the view hierarchy because the surface may have just
    /// been replaced in its parent and `host.window` could be stale.
    private func controllerHosting(_ host: SurfaceHostView) -> TerminalWindowController? {
        return host.window?.windowController as? TerminalWindowController
    }

    func performSplit(from host: SurfaceHostView,
                      direction: ghostty_action_split_direction_e) {
        guard let session = host.session, let controller = controllerHosting(host) else { return }
        let orientation: NSUserInterfaceLayoutOrientation
        let placeNewAfter: Bool
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT:
            orientation = .horizontal; placeNewAfter = true
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            orientation = .horizontal; placeNewAfter = false
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            orientation = .vertical;   placeNewAfter = true
        case GHOSTTY_SPLIT_DIRECTION_UP:
            orientation = .vertical;   placeNewAfter = false
        default:
            return
        }
        guard let newSurface = session.split(activeFrom: host,
                                             direction: orientation,
                                             placeNewAfter: placeNewAfter,
                                             runtime: self) else { return }
        controller.refreshActiveSessionTree()
        host.window?.makeFirstResponder(newSurface)
    }

    func gotoSplit(from host: SurfaceHostView,
                   target: ghostty_action_goto_split_e) {
        guard let session = host.session, let controller = controllerHosting(host) else { return }
        let next: SurfaceHostView?
        switch target {
        case GHOSTTY_GOTO_SPLIT_LEFT:     next = session.focusLeaf(in: .left)
        case GHOSTTY_GOTO_SPLIT_RIGHT:    next = session.focusLeaf(in: .right)
        case GHOSTTY_GOTO_SPLIT_UP:       next = session.focusLeaf(in: .up)
        case GHOSTTY_GOTO_SPLIT_DOWN:     next = session.focusLeaf(in: .down)
        case GHOSTTY_GOTO_SPLIT_NEXT:     next = session.focusAdjacentLeaf(forward: true)
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: next = session.focusAdjacentLeaf(forward: false)
        default: next = nil
        }
        if let next { controller.window?.makeFirstResponder(next) }
    }

    func handleSurfaceClose(_ host: SurfaceHostView) {
        guard let controller = controllerHosting(host) else { return }
        controller.handleSurfaceClose(host)
    }

    func showSearch(from host: SurfaceHostView) {
        guard let controller = controllerHosting(host) else { return }
        controller.showSearchBar(for: host)
    }

    func hideSearch(from host: SurfaceHostView) {
        controllerHosting(host)?.hideSearchBar(matchingSurface: host)
    }

    func searchTotal(from host: SurfaceHostView, total: Int) {
        controllerHosting(host)?.updateSearchCount(matchingSurface: host, total: total, selected: nil)
    }

    func searchSelected(from host: SurfaceHostView, index: Int) {
        controllerHosting(host)?.updateSearchCount(matchingSurface: host, total: nil, selected: index)
    }

    func updateTitle(from host: SurfaceHostView, to title: String) {
        guard let session = host.session,
              let controller = controllerHosting(host) else { return }
        // Respect a user rename — once the user double-clicks-renames a tab,
        // OSC titles from the shell shouldn't clobber the new name.
        if session.titleLocked { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        controller.refreshSessionTitle(session)
    }

    /// Re-read all config sources and push the result to every live surface.
    /// Called by Settings UI whenever the user changes a setting.
    func reloadConfig() {
        guard let app else { return }
        guard let newConfig = Self.buildConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        for host in liveSurfaces.allObjects {
            if let surface = host.surface {
                ghostty_surface_update_config(surface, newConfig)
            }
        }
        if let oldConfig = self.config { ghostty_config_free(oldConfig) }
        self.config = newConfig
    }
}
