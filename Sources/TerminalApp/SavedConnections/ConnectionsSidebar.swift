import AppKit

/// Left-side sidebar listing all saved connections, grouped by folder.
///
/// Single-click on a connection fires `onPick`, which the host window uses
/// to spawn a new tab. The sidebar is read-only on purpose — adding, editing,
/// folder management, and reordering live in the Connections window so the
/// sidebar stays a fast "where do I want to go" surface.
final class ConnectionsSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onPick: ((SavedConnection) -> Void)?
    var onManageConnections: (() -> Void)?

    private enum Row {
        case folder(ConnectionFolder)
        case connection(SavedConnection)
    }

    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()
    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "Connections")
    private let manageButton = NSButton()

    /// Snapshot of folders displayed at the top level.
    private var folders: [ConnectionFolder] = []
    /// Snapshot of root-level connections shown after the folders.
    private var rootConnections: [SavedConnection] = []
    /// Folder IDs the user has collapsed. Folders default to expanded.
    private var collapsedFolderIDs: Set<UUID> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Start transparent. `TerminalWindowController.applySettings` calls
        // `applyChromeColor` immediately afterwards with the live theme tint
        // so the sidebar matches the tab bar and benefits from the same
        // behind-window blur.
        layer?.backgroundColor = NSColor.clear.cgColor
        // Clip children to the sidebar bounds so when ⌘S animates the
        // width down to 0, the "Connections" header (anchored at
        // leading + 12pt) gets clipped in step with the shrinking
        // container instead of hanging over the terminal area until
        // the animation completes and `isHidden` finally fires.
        layer?.masksToBounds = true
        layoutContents()
        NotificationCenter.default.addObserver(self,
            selector: #selector(reload),
            name: ConnectionStore.changedNotification,
            object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func layoutContents() {
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        manageButton.isBordered = false
        manageButton.bezelStyle = .regularSquare
        manageButton.image = NSImage(systemSymbolName: "gearshape",
                                     accessibilityDescription: "Manage connections")
        manageButton.imagePosition = .imageOnly
        manageButton.toolTip = "Open Connections settings"
        manageButton.target = self
        manageButton.action = #selector(openManage(_:))
        manageButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(manageButton)

        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.allowsMultipleSelection = false
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowSingleClicked(_:))
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        let col = NSTableColumn(identifier: .init("conn"))
        col.title = ""
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        // Clear background on every layer in the scroll/outline stack so the
        // sidebar's tinted layer (set via applyChromeColor) shows through —
        // and so the behind-window blur reads consistently with the rest of
        // the chrome.
        outline.backgroundColor = .clear
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            manageButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            manageButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            manageButton.widthAnchor.constraint(equalToConstant: 20),
            manageButton.heightAnchor.constraint(equalToConstant: 20),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Tint the sidebar to match the chrome (theme background × opacity).
    /// The behind-window blur applied by the host window's
    /// `NSVisualEffectView` shows through this layer in proportion to the
    /// color's alpha — same trick the tab bar uses.
    func applyChromeColor(_ color: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    @objc private func reload() {
        let store = ConnectionStore.shared
        folders = store.folders
        rootConnections = store.rootConnections
        outline.reloadData()
        for folder in folders where !collapsedFolderIDs.contains(folder.id) {
            outline.expandItem(folderItem(for: folder.id))
        }
    }

    @objc private func openManage(_ sender: Any?) {
        onManageConnections?()
    }

    @objc private func rowSingleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0,
              let item = outline.item(atRow: row) as? RowItem else { return }
        // Single-click only acts on folders (toggle expansion when the row
        // body is clicked, not just the disclosure arrow). Connections
        // require a double-click to open so a click can select without
        // accidentally spawning a session.
        if case .folder = item.row {
            if outline.isItemExpanded(item) {
                outline.collapseItem(item)
            } else {
                outline.expandItem(item)
            }
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0,
              let item = outline.item(atRow: row) as? RowItem else { return }
        if case .connection(let connection) = item.row {
            onPick?(connection)
        }
    }

    // MARK: - Outline data

    /// Boxed row item — `NSOutlineView` requires reference identity to track
    /// expand/collapse state across reloads, so we keep a small class wrapper.
    private final class RowItem: NSObject {
        let row: Row
        init(_ row: Row) { self.row = row }
    }

    private var folderItems: [UUID: RowItem] = [:]

    private func folderItem(for folderID: UUID) -> RowItem {
        if let existing = folderItems[folderID] { return existing }
        let folder = folders.first { $0.id == folderID } ?? ConnectionFolder(id: folderID, name: "")
        let item = RowItem(.folder(folder))
        folderItems[folderID] = item
        return item
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? RowItem else {
            return folders.count + rootConnections.count
        }
        if case .folder(let f) = item.row {
            return ConnectionStore.shared.connections(in: f.id).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? RowItem, case .folder(let f) = item.row {
            let kids = ConnectionStore.shared.connections(in: f.id)
            return RowItem(.connection(kids[index]))
        }
        if index < folders.count {
            return folderItem(for: folders[index].id)
        }
        let connIndex = index - folders.count
        return RowItem(.connection(rootConnections[connIndex]))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? RowItem else { return false }
        if case .folder = item.row { return true }
        return false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? RowItem,
              case .folder(let f) = item.row else { return }
        collapsedFolderIDs.remove(f.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? RowItem,
              case .folder(let f) = item.row else { return }
        collapsedFolderIDs.insert(f.id)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? RowItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("sidebar-row")
        let cell: NSTableCellView = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            v.addSubview(icon)
            v.imageView = icon
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 12)
            v.addSubview(label)
            v.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()

        switch item.row {
        case .folder(let folder):
            cell.imageView?.image = NSImage(systemSymbolName: "folder",
                                            accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            cell.textField?.stringValue = folder.name.isEmpty ? "Untitled" : folder.name
            cell.textField?.font = .systemFont(ofSize: 12, weight: .medium)
        case .connection(let connection):
            cell.imageView?.image = NSImage(systemSymbolName: "terminal",
                                            accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            cell.textField?.stringValue = connection.displayName
            cell.textField?.font = .systemFont(ofSize: 12)
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 22 }
}
