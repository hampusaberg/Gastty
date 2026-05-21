import AppKit

/// Floating, blurred panel that opens with ⌘K — type to fuzzy-filter saved
/// connections, ↑/↓ to navigate, Enter to connect, Esc to dismiss.
final class QuickConnectPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    private let panel: NSPanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let onPick: (SavedConnection) -> Void
    private let onManageConnections: () -> Void

    private var filtered: [SavedConnection] = []

    /// Window we centered the panel over on the last `present()`. Used so we
    /// don't end up tracking a closed/unrelated window.
    private weak var anchorWindow: NSWindow?

    init(onPick: @escaping (SavedConnection) -> Void,
         onManageConnections: @escaping () -> Void) {
        self.onPick = onPick
        self.onManageConnections = onManageConnections
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        super.init()

        // Self-delegate the panel so we can dismiss on `windowDidResignKey`
        // — i.e. the user clicked anywhere outside the panel. The existing
        // `hidesOnDeactivate` only fires when the entire app deactivates;
        // it doesn't catch a click on our own terminal window, which is
        // what a user expects to dismiss a floating palette.
        panel.delegate = self
        layoutPanel()
        searchField.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(commit(_:))

        NotificationCenter.default.addObserver(self,
            selector: #selector(refresh),
            name: ConnectionStore.changedNotification,
            object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func layoutPanel() {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(blur)

        searchField.placeholderString = "Search connections — host, user, name…"
        searchField.font = .systemFont(ofSize: 16)
        searchField.bezelStyle = .roundedBezel
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        if let img = NSImage(systemSymbolName: "plus.circle.fill",
                             accessibilityDescription: "Manage saved connections") {
            addButton.image = img
        }
        addButton.imagePosition = .imageOnly
        addButton.imageScaling = .scaleProportionallyUpOrDown
        addButton.toolTip = "Open Connections settings"
        addButton.target = self
        addButton.action = #selector(openConnectionsSettings(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(addButton)

        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        let col = NSTableColumn(identifier: .init("conn"))
        col.title = ""; col.width = 480
        tableView.addTableColumn(col)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: content.topAnchor),
            blur.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Public

    func present() {
        refresh()
        // Anchor the panel over the currently keyed terminal window so it
        // feels like part of the app, not a system-wide overlay. Fall back
        // to the screen if no terminal window is up.
        anchorWindow = NSApp.windows.first(where: { $0.isVisible && $0.windowController is TerminalWindowController })
                       ?? NSApp.keyWindow
        let size = panel.frame.size
        let target: NSRect = anchorWindow?.frame
                             ?? NSScreen.main?.visibleFrame
                             ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2 + size.height * 0.15
        )
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.stringValue = ""
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    @objc private func openConnectionsSettings(_ sender: Any?) {
        // Use an explicit callback (no NSApp.delegate cast — that can
        // mis-resolve under SwiftUI's NSApplicationDelegateAdaptor). Defer
        // past this click event so the panel-close doesn't race window
        // activation.
        let action = onManageConnections
        panel.orderOut(nil)
        DispatchQueue.main.async {
            action()
        }
    }

    @objc private func refresh() {
        filtered = ConnectionStore.shared.filtered(by: searchField.stringValue)
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    // MARK: - NSWindowDelegate

    /// Click outside the panel → dismiss. The panel loses key status the
    /// moment another window in our app accepts focus (terminal click,
    /// menu bar interaction, settings window opening, etc.). We defer
    /// the actual `orderOut` to the next runloop tick so that the click
    /// that triggered the resign has finished routing — otherwise the
    /// outgoing click can race the close and end up landing on the
    /// panel's table view instead of the intended terminal pane.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    // MARK: - Search field

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            advanceSelection(by: +1); return true
        case #selector(NSResponder.moveUp(_:)):
            advanceSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(nil); return true
        case #selector(NSResponder.cancelOperation(_:)):
            panel.orderOut(nil); return true
        default:
            return false
        }
    }

    private func advanceSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = max(0, min(filtered.count - 1, current + delta))
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func commit(_ sender: Any?) {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        let conn = filtered[row]
        panel.orderOut(nil)
        onPick(conn)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let conn = filtered[row]
        let id = NSUserInterfaceItemIdentifier("qc-row")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.translatesAutoresizingMaskIntoConstraints = false
            let detail = NSTextField(labelWithString: "")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(title)
            cell.addSubview(detail)
            cell.textField = title
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
                detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
                detail.lastBaselineAnchor.constraint(equalTo: title.lastBaselineAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            ])
        }
        cell.textField?.stringValue = conn.displayName
        if let detail = cell.subviews.compactMap({ $0 as? NSTextField }).last(where: { $0 != cell.textField }) {
            detail.stringValue = "\(conn.user)@\(conn.host)\(conn.port == 22 ? "" : ":\(conn.port)")"
        }
        return cell
    }
}
