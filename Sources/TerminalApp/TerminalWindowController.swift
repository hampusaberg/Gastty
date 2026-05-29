import AppKit
import GhosttyKit

/// One NSWindow + multiple sessions (tabs).
///
/// We dropped native `NSWindow` tab groups in favor of a custom tab bar
/// (see `TabBarView`) so we can offer double-click-to-rename, per-tab close
/// buttons, and a custom right-click menu.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, TabBarDelegate {

    private let runtime: GhosttyRuntime
    let tabBar = TabBarView()
    private let surfaceContainer = NSView()
    private let backgroundEffect = NSVisualEffectView()
    private let chromeSeparator = NSView()
    private let searchBar = SearchBar()
    private let sidebar = ConnectionsSidebar()
    private let sidebarSeparator = NSView()
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private let sidebarOpenWidth: CGFloat = 240
    private(set) var isSidebarVisible: Bool = false
    private var activeSurfaceConstraints: [NSLayoutConstraint] = []
    private let restoreState: PersistedWindowState?

    /// Initialize and (by default) open one fresh session. Pass `restoring:`
    /// to rebuild a saved window from `PersistedWindowState` instead — the
    /// auto-opened first session is skipped.
    init(runtime: GhosttyRuntime, restoring state: PersistedWindowState? = nil) {
        self.runtime = runtime
        self.restoreState = state

        // `.fullSizeContentView` makes the contentView extend behind the
        // title bar so our NSVisualEffectView reaches all the way to the
        // top — without it, blur stops below the title bar and the top
        // strip looks visually disconnected from the rest of the window.
        // We avoid the tab-drag bug by positioning the tab bar BELOW the
        // title bar zone via `window.contentLayoutGuide.topAnchor`, so
        // tab clicks are never in AppKit's title-bar-drag region.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Gastty"
        window.center()
        window.tabbingMode = .disallowed       // we own tabs now
        window.titleVisibility = .hidden       // hide title text; chrome stays
        // Make the title bar background blend with the content beneath it —
        // the visual effect view + the tab bar — so the top of the window
        // reads as one continuous strip instead of three distinct bands.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        super.init(window: window)
        window.delegate = self

        backgroundEffect.translatesAutoresizingMaskIntoConstraints = false
        backgroundEffect.material = .hudWindow
        backgroundEffect.blendingMode = .behindWindow
        backgroundEffect.state = .inactive
        backgroundEffect.isHidden = true
        root.addSubview(backgroundEffect)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        root.addSubview(tabBar)

        surfaceContainer.translatesAutoresizingMaskIntoConstraints = false
        surfaceContainer.wantsLayer = true
        surfaceContainer.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(surfaceContainer)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        // The workspace switcher inside the tab bar needs a window
        // reference to anchor its New / Edit workspace sheets.
        tabBar.workspaceSwitcher.ownerWindow = window
        root.addSubview(tabBar)

        // 1px separator between the (title bar + tab bar) strip and the
        // terminal surface — gives the chrome a clean visual boundary
        // without breaking the uniform color above it.
        chromeSeparator.translatesAutoresizingMaskIntoConstraints = false
        chromeSeparator.wantsLayer = true
        chromeSeparator.layer?.backgroundColor =
            NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        root.addSubview(chromeSeparator)

        surfaceContainer.translatesAutoresizingMaskIntoConstraints = false
        surfaceContainer.wantsLayer = true
        surfaceContainer.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(surfaceContainer)

        // Connections sidebar lives on the left of the surface area, below
        // the chrome separator. Width animates between 0 (hidden) and
        // `sidebarOpenWidth` (shown via ⌘S). A 1px vertical rule on its
        // trailing edge gives the surface a clean visual boundary.
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.isHidden = true
        sidebar.hostWindow = window
        sidebar.onPick = { [weak self] connection in
            guard let self else { return }
            let credential = connection.credentialID.flatMap {
                CredentialStore.shared.credential(id: $0)
            }
            let command = CredentialStore.applyPasswordInjection(
                to: connection.sshCommand(with: credential),
                connection: connection)
            self.addNewSession(title: connection.displayName, command: command)
        }
        sidebar.onManageConnections = {
            // Route through the responder chain rather than casting
            // NSApp.delegate — the SwiftUI `NSApplicationDelegateAdaptor`
            // wraps the real AppDelegate, so the direct cast can return nil.
            NSApp.sendAction(#selector(AppDelegate.showConnectionsWindow(_:)),
                             to: nil, from: nil)
        }
        root.addSubview(sidebar)

        sidebarSeparator.translatesAutoresizingMaskIntoConstraints = false
        sidebarSeparator.wantsLayer = true
        sidebarSeparator.layer?.backgroundColor =
            NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        sidebarSeparator.isHidden = true
        root.addSubview(sidebarSeparator)

        // `contentLayoutGuide` is the area below the title bar — by anchoring
        // tabBar.topAnchor to it (instead of root.topAnchor) the tab bar
        // sits below the system's title-bar drag zone even though
        // contentView technically extends to the top.
        let contentLayout = window.contentLayoutGuide as? NSLayoutGuide

        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            backgroundEffect.topAnchor.constraint(equalTo: root.topAnchor),
            backgroundEffect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backgroundEffect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backgroundEffect.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            tabBar.topAnchor.constraint(equalTo: contentLayout?.topAnchor ?? root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            chromeSeparator.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            chromeSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chromeSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chromeSeparator.heightAnchor.constraint(equalToConstant: 1),

            sidebar.topAnchor.constraint(equalTo: chromeSeparator.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidthConstraint,

            sidebarSeparator.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarSeparator.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarSeparator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarSeparator.widthAnchor.constraint(equalToConstant: 1),

            surfaceContainer.topAnchor.constraint(equalTo: chromeSeparator.bottomAnchor),
            surfaceContainer.leadingAnchor.constraint(equalTo: sidebarSeparator.trailingAnchor),
            surfaceContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surfaceContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Find bar: floats above the terminal surface, hidden by default.
        // Shown by libghostty firing START_SEARCH when the user hits ⌘F.
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        searchBar.wantsLayer = true
        searchBar.layer?.cornerRadius = 6
        searchBar.layer?.borderWidth = 1
        searchBar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        root.addSubview(searchBar, positioned: .above, relativeTo: surfaceContainer)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: chromeSeparator.bottomAnchor, constant: 12),
            searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchBar.heightAnchor.constraint(equalToConstant: 32),
            searchBar.widthAnchor.constraint(equalToConstant: 360),
        ])

        applySettings(SettingsStore.shared.settings)

        if let restoreState {
            if let frame = restoreState.frame?.rect {
                window.setFrame(frame, display: false)
            }
            for sessionState in restoreState.sessions {
                let session = Session(runtime: runtime, restoring: sessionState)
                tabBar.add(session: session, activate: false)
            }
            if !restoreState.sessions.isEmpty {
                let idx = max(0, min(restoreState.activeSessionIndex,
                                     restoreState.sessions.count - 1))
                tabBar.activate(index: idx)
            } else {
                addNewSession()  // safety: never end up with an empty window
            }
        } else {
            addNewSession()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Sessions

    @discardableResult
    func addNewSession(title: String = "Gastty", command: String? = nil) -> Session {
        let session = Session(runtime: runtime, title: title, command: command)
        tabBar.add(session: session, activate: true)
        // setActive (inside tabBar.add) routes through TabBarDelegate, which
        // installs the surface view for us — no manual install needed here.
        return session
    }

    func closeActiveSession() {
        guard let active = tabBar.activeSession else { return }
        confirmCloseIfRunning(
            scope: active.rootNode.allLeaves(),
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) { [weak self] in
            guard let self else { return }
            self.tabBar.remove(session: active)
            if self.tabBar.isEmpty {
                self.window?.performClose(nil)
            }
        }
    }

    /// ⌘W behavior: if the active session has more than one pane, close
    /// only the focused pane and re-render. Otherwise close the whole tab
    /// (and the window if it was the last tab).
    func closeActivePaneOrTab() {
        guard let active = tabBar.activeSession else { return }
        if active.rootNode.allLeaves().count > 1 {
            let surface = active.activeSurface
            confirmCloseIfRunning(
                scope: [surface],
                messageText: "Close Pane?",
                informativeText: "This pane still has a running process. If you close it the process will be killed."
            ) { [weak self] in
                self?.handleSurfaceClose(surface)
            }
        } else {
            closeActiveSession()
        }
    }

    /// Show the "running process" sheet over the active window if any
    /// surface in `scope` reports a live child PID, and only call
    /// `proceed` on confirm. When nothing's running we skip straight
    /// to `proceed`, so close-when-idle still feels instant.
    ///
    /// libghostty's `ghostty_surface_needs_confirm_quit` returns true
    /// when the surface has a child process that isn't the user's
    /// login shell — i.e. SSH, vim, claude, anything they'd hate to
    /// lose to a stray ⌘W.
    private func confirmCloseIfRunning(
        scope: [SurfaceHostView],
        messageText: String,
        informativeText: String,
        proceed: @escaping () -> Void
    ) {
        let hasRunning = scope.contains { host in
            guard let surface = host.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }
        guard hasRunning, let window else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                proceed()
            }
        }
    }

    func activateTab(at index: Int) { tabBar.activate(index: index) }
    func activateLastTab() { tabBar.activate(index: tabBar.count - 1) }
    var sessionCount: Int { tabBar.count }

    // MARK: - Connections sidebar

    /// Toggle the saved-connections sidebar on the left of the surface area.
    /// Bound to ⌘S in the View menu.
    func toggleConnectionsSidebar() {
        isSidebarVisible.toggle()
        if isSidebarVisible {
            sidebar.isHidden = false
            sidebarSeparator.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sidebarWidthConstraint.animator().constant =
                isSidebarVisible ? sidebarOpenWidth : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.isSidebarVisible {
                self.sidebar.isHidden = true
                self.sidebarSeparator.isHidden = true
            }
        })
    }

    // MARK: - TabBarDelegate

    func tabBar(_ bar: TabBarView, didActivate session: Session) {
        installSurfaceView(for: session)
        window?.title = session.title
    }

    func tabBar(_ bar: TabBarView, didRequestCloseOf session: Session) {
        confirmCloseIfRunning(
            scope: session.rootNode.allLeaves(),
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) { [weak self] in
            guard let self else { return }
            bar.remove(session: session)
            if bar.isEmpty {
                self.window?.performClose(nil)
            }
        }
    }

    func tabBar(_ bar: TabBarView, didRequestDuplicateOf session: Session) {
        addNewSession(title: session.title)
    }

    func tabBarRequestsNewTab(_ bar: TabBarView) {
        addNewSession()
    }

    // MARK: - Surface plumbing

    private func installSurfaceView(for session: Session) {
        NSLayoutConstraint.deactivate(activeSurfaceConstraints)
        surfaceContainer.subviews.forEach { $0.removeFromSuperview() }
        let view = session.renderTreeView()
        view.translatesAutoresizingMaskIntoConstraints = false
        surfaceContainer.addSubview(view)
        activeSurfaceConstraints = [
            view.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(activeSurfaceConstraints)
        window?.makeFirstResponder(session.activeSurface)
    }

    /// Refresh the rendered tree (e.g. after a split mutation) without
    /// touching tab state or focus selection.
    func refreshActiveSessionTree() {
        guard let active = tabBar.activeSession else { return }
        installSurfaceView(for: active)
    }

    // MARK: - Search

    func showSearchBar(for host: SurfaceHostView) {
        searchBar.present(over: host)
    }

    func hideSearchBar(matchingSurface host: SurfaceHostView? = nil) {
        // If a surface is supplied, only dismiss if the bar is targeting
        // that surface (avoids dismissing while user is searching another tab).
        if let host, searchBar.surface !== host { return }
        searchBar.dismiss()
    }

    func updateSearchCount(matchingSurface host: SurfaceHostView,
                           total: Int? = nil,
                           selected: Int? = nil) {
        guard searchBar.surface === host else { return }
        if let total { searchBar.total = total }
        if let selected { searchBar.selected = selected }
    }

    /// Called after `session.title` changes so the tab UI + window title
    /// stay in sync with whatever the shell set.
    func refreshSessionTitle(_ session: Session) {
        tabBar.refreshTitles()
        if tabBar.activeSession?.id == session.id {
            window?.title = session.title
        }
    }

    /// Called by the runtime when a surface signals close (process exited or
    /// user-triggered close). Remove the leaf; if the session is now empty,
    /// close the tab.
    func handleSurfaceClose(_ host: SurfaceHostView) {
        guard let session = host.session,
              tabBar.sessions.contains(where: { $0 === session }) else { return }
        let empty = session.remove(surface: host)
        if empty {
            tabBar.remove(session: session)
            if tabBar.isEmpty { window?.performClose(nil) }
        } else if tabBar.activeSession === session {
            installSurfaceView(for: session)
        }
    }

    // MARK: - Settings application

    /// Apply settings to the window chrome (transparency, blur, theme color).
    /// The libghostty surface itself receives its own config update via
    /// `reloadConfig` on the runtime.
    func applySettings(_ settings: AppSettings) {
        guard let window else { return }
        let themeBg = currentThemeBackground()
        let chromeColor = themeBg.withAlphaComponent(CGFloat(settings.backgroundOpacity))

        // We always allow transparency so libghostty's `background-opacity`
        // actually reads through. `window.backgroundColor` carries the
        // theme color at the slider's alpha — keeps the chrome tinted with
        // the same color as the terminal instead of going see-through.
        window.isOpaque = false
        window.backgroundColor = chromeColor
        window.hasShadow = true

        // Light themes get the `aqua` appearance so the traffic lights and
        // window text use dark glyphs; dark themes get `darkAqua` for the
        // standard light glyphs.
        window.appearance = NSAppearance(named: isLight(themeBg) ? .aqua : .darkAqua)

        // Tab bar tracks the same chrome color. The chromeSeparator and
        // title bar both blend with it for the uniform top-of-window look.
        tabBar.layer?.backgroundColor = chromeColor.cgColor

        // Connections sidebar shares the chrome tint so it reads as part of
        // the same surrounding shell — and so the behind-window blur shows
        // through it at the same opacity as the tab bar.
        sidebar.applyChromeColor(chromeColor)

        // Blur: 4 discrete materials. NSVisualEffectView doesn't expose a
        // numeric blur radius, so a slider was fake — these are the actual
        // levels the API gives us. Ranked lightest → heaviest based on
        // perceptual obstruction.
        switch settings.blurLevel {
        case .off:
            backgroundEffect.isHidden = true
            backgroundEffect.state = .inactive
        case .light:
            // `.headerView` is one of the most translucent materials Apple
            // exposes — minimal tint, only a subtle blur halo. Used to feel
            // closer to "Off" than to "Medium".
            backgroundEffect.isHidden = false
            backgroundEffect.state = .active
            backgroundEffect.material = .headerView
        case .medium:
            backgroundEffect.isHidden = false
            backgroundEffect.state = .active
            backgroundEffect.material = .windowBackground
        case .strong:
            backgroundEffect.isHidden = false
            backgroundEffect.state = .active
            backgroundEffect.material = .hudWindow
        }
    }

    /// Read the active theme's background color from libghostty's config.
    /// Falls back to a neutral system color if libghostty can't tell us.
    private func currentThemeBackground() -> NSColor {
        guard let config = GhosttyRuntime.shared.config else {
            return NSColor.controlBackgroundColor
        }
        var bg = ghostty_config_color_s()
        let key = "background"
        let success = key.withCString { keyPtr -> Bool in
            ghostty_config_get(config, &bg, keyPtr, UInt(key.utf8.count))
        }
        guard success else { return NSColor.controlBackgroundColor }
        return NSColor(
            srgbRed: CGFloat(bg.r) / 255.0,
            green: CGFloat(bg.g) / 255.0,
            blue: CGFloat(bg.b) / 255.0,
            alpha: 1
        )
    }

    private func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        // Standard relative-luminance formula (Rec. 601 weights).
        let l = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return l > 0.55
    }

    // MARK: - NSWindowDelegate

    /// Force-push surface focus to libghostty whenever the window
    /// becomes key. Without this, after a deep sleep AppKit may not
    /// re-make the surface view the firstResponder, so libghostty
    /// stays in "unfocused" state — the cursor stops highlighting,
    /// and the kitty keyboard protocol behaves differently (Ctrl+W
    /// in particular ends up echoing the tail of its CSI encoding
    /// as literal text instead of acting as delete-word).
    func windowDidBecomeKey(_ notification: Notification) {
        refreshSurfaceFocus()
    }

    /// Re-assert focus on the active session's surface. Called from
    /// windowDidBecomeKey and from AppDelegate on wake/become-active
    /// so the libghostty focus state is always synced with what the
    /// user sees.
    func refreshSurfaceFocus() {
        guard let active = tabBar.activeSession else { return }
        if let surface = active.activeSurface.surface {
            ghostty_surface_set_focus(surface, true)
        }
        // Also kick AppKit into making the surface view the
        // firstResponder so keyDown events route correctly.
        window?.makeFirstResponder(active.activeSurface)
    }

    func windowWillClose(_ notification: Notification) {
        if let app = NSApp.delegate as? AppDelegate {
            app.purge(self)
            // If this was the last terminal window, quit the app. Without
            // this an open Settings/Connections window would keep the
            // process alive even after the user closed every terminal.
            let remaining = NSApp.windows.contains { other in
                other !== window
                    && other.windowController is TerminalWindowController
                    && other.isVisible
            }
            if !remaining {
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
}
