import AppKit
import GhosttyKit
import UserNotifications
import Sparkle

/// Owns the macOS application lifecycle: builds the menu bar, opens the first
/// window on launch, and brokers actions like new-window / new-tab / close.
///
/// We do menus and windows in AppKit (not SwiftUI's `.commands` / `WindowGroup`)
/// because SwiftUI's window machinery doesn't give us reliable control over
/// the responder chain plumbing needed for custom tab bars and panels.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controllers: [TerminalWindowController] = []
    private var connectionsWindow: ConnectionsWindowController?
    private var quickConnectPanel: QuickConnectPanel?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

    /// Sparkle's controller — owns the background update timer + the UI
    /// it presents when a new version is available. Held by AppDelegate
    /// for the app's lifetime. Reads its config from Info.plist
    /// (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`).
    ///
    /// Sparkle 2.x refuses to start when the host bundle isn't signed
    /// with a Developer ID certificate, which Debug builds never have —
    /// instead it surfaces a "The updater failed to start" alert that's
    /// pure noise during local development. Gate the controller behind
    /// `#if !DEBUG` so Debug runs skip Sparkle entirely; Release builds
    /// (which is what ships in the DMG) get the full machinery.
    #if DEBUG
    private let updaterController: SPUStandardUpdaterController? = nil
    #else
    private lazy var updaterController: SPUStandardUpdaterController? = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
        NSApp.applicationIconImage = Self.makeAppIcon()
        _ = SettingsStore.shared               // generates runtime.conf early
        _ = GhosttyRuntime.shared              // loads runtime.conf during init
        _ = WorkspaceStore.shared              // bootstrap workspaces + migrate
        _ = ConnectionStore.shared             // loads from active workspace

        // Listen for workspace switches so we can save the current
        // tabs/splits into the OLD workspace's state before AppKit
        // closes them, then restore the new workspace's state.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceWillSwitch(_:)),
            name: WorkspaceStore.willSwitch,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceDidSwitch(_:)),
            name: WorkspaceStore.didSwitch,
            object: nil
        )

        // Request notification permission for "command finished" alerts.
        // Async — the user sees the system prompt once on first launch;
        // until they grant it, command-finished notifications silently
        // no-op. Not fatal if they decline.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in /* user choice persists in macOS settings */ }

        // First-run onboarding takes precedence over both restore and
        // new-window — once the user finishes (or dismisses), the
        // continuation opens the first terminal window for them.
        if !SettingsStore.shared.settings.hasCompletedOnboarding {
            // Run the appcast probe BEFORE the welcome window so a
            // user on a stale DMG (e.g. a colleague's old copy passed
            // around in Slack) is offered the latest version first.
            // The check resolves to `.upToDate` on any failure mode
            // (no network, slow feed, malformed XML) so first launch
            // stays snappy even when offline.
            checkForUpdateThenOnboard()
        } else if let saved = AppPersistence.load(), !saved.windows.isEmpty {
            restoreWindows(from: saved)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openNewWindow(self)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Any change in Settings → regenerate config and broadcast to every
        // live surface + update each window's chrome (opacity / blur).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: SettingsStore.changedNotification,
            object: nil
        )
    }

    // MARK: - Workspace switching

    /// Frames of the current windows captured at `willSwitch` and
    /// re-applied to the new workspace's restored windows in
    /// `didSwitch` so the user's chosen window layout (size + screen
    /// position) is preserved across the switch. Without this, each
    /// workspace's windows snap back to whatever frame was saved when
    /// they were last quit, which feels jarring.
    private var pendingSwitchFrames: [NSRect] = []

    /// Fired BEFORE `WorkspaceStore.activeID` changes. Snapshot the
    /// current windows into the OLD workspace's state.json — at this
    /// point `WorkspaceStore.activeWorkspaceDirectory` still resolves
    /// to the old workspace's folder, so `AppPersistence.save` writes
    /// to the right place. Also captures frames for re-use in
    /// `didSwitch`.
    @objc private func workspaceWillSwitch(_ note: Notification) {
        AppPersistence.save(snapshotState())
        pendingSwitchFrames = controllers.compactMap { $0.window?.frame }
    }

    /// Fired AFTER the active workspace changed. Open the new
    /// workspace's saved tabs FIRST, then close the old windows — that
    /// way the in-between moment isn't "zero terminal windows," which
    /// would trigger `applicationShouldTerminateAfterLastWindowClosed`
    /// and quit the app mid-switch.
    @objc private func workspaceDidSwitch(_ note: Notification) {
        let oldControllers = controllers
        let frames = pendingSwitchFrames
        pendingSwitchFrames = []
        controllers = []
        if let saved = AppPersistence.load(), !saved.windows.isEmpty {
            restoreWindows(from: saved)
        } else {
            openNewWindow(self)
        }
        // Re-position the restored windows over the OLD workspace's
        // window frames, by index. Anything past the captured count
        // (e.g. target has more windows than we started with) keeps
        // its restored frame.
        for (idx, frame) in frames.enumerated() where idx < controllers.count {
            controllers[idx].window?.setFrame(frame, display: true)
        }
        // Old windows close through the normal path; the `remaining`
        // check in `TerminalWindowController.windowWillClose` sees the
        // freshly-opened new workspace windows and skips the terminate.
        for old in oldControllers {
            old.window?.close()
        }
    }

    @objc private func settingsDidChange(_ note: Notification) {
        GhosttyRuntime.shared.reloadConfig()
        for controller in controllers {
            controller.applySettings(SettingsStore.shared.settings)
        }
    }

    /// Probe the appcast on launch and, if a newer version is shipping,
    /// offer the user the chance to grab it before they bother going
    /// through onboarding. Always shows onboarding at the end of the
    /// flow — either the user picks "Continue" (immediate), or they
    /// pick "Update" (Sparkle's install dialog takes over; the
    /// onboarding window sits behind it as a fallback if they cancel).
    ///
    /// On any failure to reach the feed (offline, slow, malformed) we
    /// silently fall through to onboarding so a first launch never
    /// hangs on a network issue.
    private func checkForUpdateThenOnboard() {
        let info = Bundle.main.infoDictionary
        let currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let feedURLString = (info?["SUFeedURL"] as? String) ?? ""

        let proceedToOnboarding: () -> Void = { [weak self] in
            guard let self else { return }
            self.showOnboarding { [weak self] in
                guard let self else { return }
                if let saved = AppPersistence.load(), !saved.windows.isEmpty {
                    self.restoreWindows(from: saved)
                } else {
                    self.openNewWindow(self)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // If Sparkle isn't live in this build (Debug), the "Update" path
        // can't do anything useful — skip the probe entirely and just
        // run onboarding. The check itself would succeed, but the
        // resulting alert would lead to a dead-end.
        guard updaterController != nil, let feedURL = URL(string: feedURLString) else {
            proceedToOnboarding()
            return
        }

        OnboardingUpdateCheck.check(feedURL: feedURL, currentVersion: currentVersion) { [weak self] result in
            guard let self else { return }
            switch result {
            case .upToDate:
                proceedToOnboarding()
            case .updateAvailable(let latest):
                self.presentPreOnboardingUpdateAlert(
                    current: currentVersion,
                    latest: latest,
                    proceed: proceedToOnboarding
                )
            }
        }
    }

    /// The modal shown before onboarding when a newer release exists.
    /// Two paths: install the newer version via Sparkle, or continue
    /// with the running version. We always proceed to the onboarding
    /// window afterwards — if the user picked "Update", Sparkle's own
    /// install dialog stacks on top, and the onboarding is there as a
    /// safety net should they back out of the update.
    private func presentPreOnboardingUpdateAlert(
        current: String,
        latest: String,
        proceed: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "A newer version of Gastty is available"
        alert.informativeText = """
            You're running \(current). Version \(latest) is available with the latest features and fixes.

            We recommend updating before setting things up, so your preferences carry forward into the current release.
            """
        alert.addButton(withTitle: "Update to \(latest)…")
        alert.addButton(withTitle: "Continue with \(current)")
        // The icon defaults to the app icon, which we want — keeps the
        // alert feeling like it belongs to Gastty rather than a system
        // chime.

        // We need a host window for `runModal` to attach to so the
        // alert renders sensibly even though no app windows are open
        // yet. `runModal()` (without a sheet) is fine here.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Hand off to Sparkle. Its dialog will show release notes
            // and offer Install / Skip / Later — we don't reimplement
            // that. Meanwhile we still raise the onboarding window so
            // it's already up if the user backs out of Sparkle's flow.
            updaterController?.checkForUpdates(nil)
            proceed()
        default:
            // "Continue with X.Y.Z" — straight to onboarding.
            proceed()
        }
    }

    /// First-run onboarding. The `completion` callback runs after the
    /// window closes (whether the user finished or dismissed), at which
    /// point the caller opens the actual terminal window. We hold a
    /// strong reference to the controller until then via
    /// `self.onboardingWindow` so it isn't deallocated mid-flow.
    private func showOnboarding(completion: @escaping () -> Void) {
        let controller = OnboardingWindowController { [weak self] in
            self?.onboardingWindow = nil
            completion()
        }
        onboardingWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.showWindow(sender)
        settingsWindow?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func showCustomAboutPanel(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A fast, GPU-accelerated terminal for macOS.\n" +
                    "Built on libghostty.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Gastty",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
            .applicationIcon: Self.makeAppIcon(),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Generate a basic terminal-looking icon at runtime. macOS Sequoia
    /// icons sit inside an 824pt squircle centered in a 1024pt canvas —
    /// the empty padding is what makes them feel "right-sized" next to
    /// system icons in the Dock and ⌘-Tab switcher.
    private static func makeAppIcon() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size, flipped: false) { rect in
            // Apple's icon grid: body occupies the center 824x824 of a
            // 1024x1024 canvas, with corners rounded ≈22% of body size.
            let bodyInset: CGFloat = 100
            let body = rect.insetBy(dx: bodyInset, dy: bodyInset)
            let radius: CGFloat = 184

            // Background squircle
            let bgPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            NSColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1).setFill()
            bgPath.fill()

            // Subtle inner stroke for depth
            let innerInset = body.insetBy(dx: 12, dy: 12)
            let strokePath = NSBezierPath(roundedRect: innerInset,
                                          xRadius: radius - 12,
                                          yRadius: radius - 12)
            NSColor(white: 1, alpha: 0.06).setStroke()
            strokePath.lineWidth = 4
            strokePath.stroke()

            // Prompt glyph — sized relative to the body, not the canvas.
            let text: NSString = "›_"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: body.height * 0.45, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.65, green: 0.78, blue: 1.0, alpha: 1),
            ]
            let glyphSize = text.size(withAttributes: attrs)
            let glyphRect = NSRect(
                x: body.midX - glyphSize.width / 2,
                y: body.midY - glyphSize.height / 2 - 30,
                width: glyphSize.width,
                height: glyphSize.height
            )
            text.draw(in: glyphRect, withAttributes: attrs)
            return true
        }
        return image
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The Connections window doesn't count — quit only when the user
        // explicitly closes terminal windows.
        let terminalWindowsRemaining = NSApp.windows.contains { window in
            window.windowController is TerminalWindowController && window.isVisible
        }
        return !terminalWindowsRemaining
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Snapshot tabs / splits / cwds so the next launch can rebuild
        // them. Saved to `state.json` in our App Support folder.
        AppPersistence.save(snapshotState())
    }

    private func snapshotState() -> PersistedAppState {
        let windowStates = controllers.compactMap { controller -> PersistedWindowState? in
            guard controller.window?.isVisible == true else { return nil }
            let sessions = controller.tabBar.sessions
            guard !sessions.isEmpty else { return nil }
            let activeIdx = controller.tabBar.activeSession.flatMap { active in
                sessions.firstIndex(where: { $0.id == active.id })
            } ?? 0
            return PersistedWindowState(
                frame: controller.window.map { PersistedFrame($0.frame) },
                sessions: sessions.map { $0.toPersisted() },
                activeSessionIndex: activeIdx
            )
        }
        return PersistedAppState(windows: windowStates)
    }

    private func restoreWindows(from state: PersistedAppState) {
        for windowState in state.windows {
            let controller = TerminalWindowController(runtime: .shared, restoring: windowState)
            controllers.append(controller)
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Window/tab actions (responder-chain entry points)

    @objc func openNewWindow(_ sender: Any?) {
        let controller = TerminalWindowController(runtime: .shared)
        controllers.append(controller)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    /// ⌘T — add a tab to the current window. Falls back to opening a new
    /// window if no terminal window is keyed (e.g. the Connections window
    /// is up).
    @objc func newTabInCurrentWindow(_ sender: Any?) {
        if let controller = currentTerminalController() {
            controller.addNewSession()
        } else {
            openNewWindow(sender)
        }
    }

    /// ⌘W — close the active pane if the current tab has multiple panes,
    /// otherwise close the tab. If it was the last tab, the window closes too.
    @objc func closeActiveSession(_ sender: Any?) {
        if let controller = currentTerminalController() {
            controller.closeActivePaneOrTab()
        } else {
            NSApp.keyWindow?.performClose(sender)
        }
    }

    /// ⌘1..⌘8 → that tab in the current window. ⌘9 → last tab.
    @objc func selectTab(_ sender: NSMenuItem) {
        guard let controller = currentTerminalController() else { return }
        if sender.tag == 8 {
            controller.activateLastTab()
        } else {
            controller.activateTab(at: sender.tag)
        }
    }

    @objc func showConnectionsWindow(_ sender: Any?) {
        if connectionsWindow == nil {
            connectionsWindow = ConnectionsWindowController()
        }
        guard let window = connectionsWindow?.window else { return }
        // Bring the app back into focus first — when triggered from the
        // Quick Connect panel's orderOut, the app may briefly deactivate,
        // and `makeKeyAndOrderFront` alone won't pop the window above
        // other apps' windows.
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(sender)
        window.orderFrontRegardless()
    }

    /// ⌘S — show or hide the saved-connections sidebar on the keyed window.
    @objc func toggleConnectionsSidebar(_ sender: Any?) {
        guard let controller = currentTerminalController() else { return }
        controller.toggleConnectionsSidebar()
    }

    @objc func showQuickConnect(_ sender: Any?) {
        if quickConnectPanel == nil {
            quickConnectPanel = QuickConnectPanel(
                onPick: { [weak self] connection in
                    self?.openConnection(connection)
                },
                onManageConnections: { [weak self] in
                    self?.showConnectionsWindow(nil)
                }
            )
        }
        quickConnectPanel?.present()
    }

    func openConnection(_ connection: SavedConnection) {
        // Open in the current window as a new tab, or a new window if none.
        let controller = currentTerminalController() ?? {
            let new = TerminalWindowController(runtime: .shared)
            controllers.append(new)
            new.window?.makeKeyAndOrderFront(nil)
            return new
        }()
        controller.addNewSession(title: connection.displayName, command: connection.sshCommand)
    }

    func purge(_ controller: TerminalWindowController) {
        controllers.removeAll { $0 === controller }
    }

    private func currentTerminalController() -> TerminalWindowController? {
        if let c = NSApp.keyWindow?.windowController as? TerminalWindowController { return c }
        return controllers.last
    }

    // MARK: - Menu construction

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // ---- App
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Gastty",
                        action: #selector(showCustomAboutPanel(_:)),
                        keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        // Sparkle's standard menu action — checks the appcast and
        // presents the install dialog if a newer version is available,
        // otherwise shows the "up to date" sheet. Only attached when
        // Sparkle is live (Release builds); Debug skips it because
        // Sparkle won't function without a Developer ID signature.
        if let updater = updaterController {
            let updateItem = appMenu.addItem(withTitle: "Check for Updates…",
                                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                              keyEquivalent: "")
            updateItem.target = updater
            appMenu.addItem(.separator())
        }
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(showSettings(_:)),
                                           keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Gastty",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Gastty",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ---- File
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu

        fileMenu.addItem(withTitle: "New Window",
                         action: #selector(openNewWindow(_:)),
                         keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(newTabInCurrentWindow(_:)),
                         keyEquivalent: "t").target = self
        fileMenu.addItem(.separator())
        let quick = fileMenu.addItem(withTitle: "Quick Connect…",
                                     action: #selector(showQuickConnect(_:)),
                                     keyEquivalent: "k")
        quick.target = self
        fileMenu.addItem(withTitle: "Connections…",
                         action: #selector(showConnectionsWindow(_:)),
                         keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(closeActiveSession(_:)),
                         keyEquivalent: "w").target = self

        // ---- Edit (handled by SurfaceHostView via responder chain)
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        // ---- View
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        let sidebarItem = viewMenu.addItem(withTitle: "Toggle Connections Sidebar",
                                           action: #selector(toggleConnectionsSidebar(_:)),
                                           keyEquivalent: "s")
        sidebarItem.target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(SurfaceHostView.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(SurfaceHostView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(SurfaceHostView.zoomReset(_:)), keyEquivalent: "0")

        // ---- Window
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        // ⌘1..⌘9 — tab switching in the current window.
        windowMenu.addItem(.separator())
        for i in 1...9 {
            let item = windowMenu.addItem(
                withTitle: i == 9 ? "Show Last Tab" : "Show Tab \(i)",
                action: #selector(selectTab(_:)),
                keyEquivalent: "\(i)"
            )
            item.target = self
            item.tag = i - 1
        }

        return main
    }
}
