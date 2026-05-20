import AppKit
import GhosttyKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = makeMainMenu()
        NSApp.applicationIconImage = Self.makeAppIcon()
        _ = SettingsStore.shared               // generates runtime.conf early
        _ = GhosttyRuntime.shared              // loads runtime.conf during init
        _ = ConnectionStore.shared
        openNewWindow(self)
        NSApp.activate(ignoringOtherApps: true)

        // Any change in Settings → regenerate config and broadcast to every
        // live surface + update each window's chrome (opacity / blur).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: SettingsStore.changedNotification,
            object: nil
        )
    }

    @objc private func settingsDidChange(_ note: Notification) {
        GhosttyRuntime.shared.reloadConfig()
        for controller in controllers {
            controller.applySettings(SettingsStore.shared.settings)
        }
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
