import AppKit

/// Manage saved SSH connections: list, add, edit, delete, organize into
/// folders, and reorder.
///
/// The view is an outline showing folders at the top level (with their
/// connections as children) followed by root-level connections. Rows can
/// be dragged to reorder or to move a connection into / out of a folder.
final class ConnectionsWindowController: NSWindowController, NSWindowDelegate,
                                          NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()
    private let toolbar = NSView()
    private let addButton = NSButton()
    private let addFolderButton = NSButton()
    private let editButton = NSButton()
    private let removeButton = NSButton()
    /// Switches between "show only this workspace" (folder hierarchy)
    /// and "show every connection across every workspace" (flat list).
    private let modeSegments = NSSegmentedControl(
        labels: ["This Workspace", "All Connections"],
        trackingMode: .selectOne,
        target: nil, action: nil)

    enum DisplayMode: Int {
        case thisWorkspace = 0
        case allConnections = 1
    }
    private var displayMode: DisplayMode = .thisWorkspace

    /// In `.allConnections` mode, the flat list shown by the outline.
    /// Empty in `.thisWorkspace` mode (the outline reads `folders` +
    /// `rootConnections` instead).
    private var allConnections: [SavedConnection] = []

    /// Pasteboard type used while dragging rows around inside the outline.
    /// Carries `connection:<uuid>` or `folder:<uuid>` as a UTF-8 string.
    private static let dragPasteboardType = NSPasteboard.PasteboardType("com.hampusaberg.Gastty.connection-row")

    private enum Row {
        case folder(ConnectionFolder)
        case connection(SavedConnection)
    }

    private final class RowItem: NSObject {
        let row: Row
        init(_ row: Row) { self.row = row }
    }

    private var folderItems: [UUID: RowItem] = [:]
    private var folders: [ConnectionFolder] = []
    private var rootConnections: [SavedConnection] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Connections"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        layoutContents()
        refresh()
        NotificationCenter.default.addObserver(self,
            selector: #selector(refresh),
            name: ConnectionStore.changedNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Layout

    private func layoutContents() {
        guard let content = window?.contentView else { return }

        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.usesAlternatingRowBackgroundColors = true
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = false
        outline.headerView = NSTableHeaderView()
        outline.target = self
        outline.doubleAction = #selector(editSelected(_:))
        outline.registerForDraggedTypes([Self.dragPasteboardType])

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"; nameCol.minWidth = 180; nameCol.width = 220
        outline.addTableColumn(nameCol)
        outline.outlineTableColumn = nameCol
        let userHostCol = NSTableColumn(identifier: .init("userHost"))
        userHostCol.title = "user@host"; userHostCol.width = 200
        outline.addTableColumn(userHostCol)
        let portCol = NSTableColumn(identifier: .init("port"))
        portCol.title = "Port"; portCol.width = 50
        outline.addTableColumn(portCol)
        // Workspaces column shows small SF Symbol badges for every
        // workspace this connection belongs to — useful in both modes,
        // but especially in "All Connections" where it's the primary
        // way to see "where does this live?".
        let workspacesCol = NSTableColumn(identifier: .init("workspaces"))
        workspacesCol.title = "Workspaces"; workspacesCol.width = 110
        outline.addTableColumn(workspacesCol)

        // Mode segmented control sits above the outline. Defaults to
        // "This Workspace" so existing users land on the familiar view.
        modeSegments.translatesAutoresizingMaskIntoConstraints = false
        modeSegments.selectedSegment = displayMode.rawValue
        modeSegments.target = self
        modeSegments.action = #selector(modeChanged(_:))
        modeSegments.segmentDistribution = .fillEqually
        content.addSubview(modeSegments)

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)

        for (button, title, action) in [
            (addButton, "Add", #selector(add(_:))),
            (addFolderButton, "New Folder", #selector(addFolder(_:))),
            (editButton, "Edit", #selector(editSelected(_:))),
            (removeButton, "Remove", #selector(removeSelected(_:))),
        ] {
            button.bezelStyle = .rounded
            button.title = title
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(button)
        }

        NSLayoutConstraint.activate([
            modeSegments.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            modeSegments.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            modeSegments.widthAnchor.constraint(equalToConstant: 280),

            scrollView.topAnchor.constraint(equalTo: modeSegments.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            addButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            addButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addFolderButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            addFolderButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            editButton.leadingAnchor.constraint(equalTo: addFolderButton.trailingAnchor, constant: 6),
            editButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 6),
            removeButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])
    }

    @objc private func refresh() {
        let store = ConnectionStore.shared
        if displayMode == .thisWorkspace {
            folders = store.folders
            rootConnections = store.rootConnections
            allConnections = []
        } else {
            folders = []
            rootConnections = []
            allConnections = store.allConnections.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        // Prune cached folder items so we don't carry references to deleted folders.
        let activeIDs = Set(folders.map { $0.id })
        folderItems = folderItems.filter { activeIDs.contains($0.key) }
        outline.reloadData()
        for folder in folders {
            outline.expandItem(folderItem(for: folder.id))
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard let newMode = DisplayMode(rawValue: sender.selectedSegment) else { return }
        displayMode = newMode
        // Folder operations don't apply when viewing the global list,
        // since folders are per-workspace. Disable the New Folder
        // button so it's clear that's intentional.
        addFolderButton.isEnabled = (newMode == .thisWorkspace)
        refresh()
    }

    private func folderItem(for folderID: UUID) -> RowItem {
        if let existing = folderItems[folderID] { return existing }
        let folder = folders.first { $0.id == folderID } ?? ConnectionFolder(id: folderID, name: "")
        let item = RowItem(.folder(folder))
        folderItems[folderID] = item
        return item
    }

    // MARK: - Actions

    @objc private func add(_ sender: Any?) {
        ConnectionEditor.present(over: window!, editing: nil) { conn, workspaces in
            ConnectionStore.shared.add(conn, toWorkspaces: workspaces)
        }
    }

    @objc private func addFolder(_ sender: Any?) {
        FolderNameEditor.present(over: window!, existingName: nil) { name in
            ConnectionStore.shared.addFolder(name: name)
        }
    }

    @objc private func editSelected(_ sender: Any?) {
        guard let item = outline.item(atRow: outline.selectedRow) as? RowItem else { return }
        switch item.row {
        case .connection(let existing):
            ConnectionEditor.present(over: window!, editing: existing) { conn, workspaces in
                ConnectionStore.shared.update(conn)
                ConnectionStore.shared.setWorkspaces(workspaces, for: conn.id)
            }
        case .folder(let folder):
            FolderNameEditor.present(over: window!, existingName: folder.name) { name in
                ConnectionStore.shared.renameFolder(folder.id, to: name)
            }
        }
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard let item = outline.item(atRow: outline.selectedRow) as? RowItem else { return }
        let alert = NSAlert()
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        switch item.row {
        case .connection(let conn):
            if displayMode == .allConnections {
                // Global view → delete the connection from every
                // workspace it's in and from the global list. This is
                // the destructive "wipe this connection" path.
                alert.messageText = "Delete \(conn.displayName) everywhere?"
                let inWorkspaces = ConnectionStore.shared.workspaces(for: conn.id).count
                alert.informativeText = inWorkspaces > 1
                    ? "Removes it from all \(inWorkspaces) workspaces. This can't be undone."
                    : "This can't be undone."
                if alert.runModal() == .alertFirstButtonReturn {
                    ConnectionStore.shared.removeFromAllWorkspaces(conn)
                }
            } else {
                // Workspace view → remove just from THIS workspace.
                // If it isn't in any other workspaces, the global
                // record also goes (handled inside the store).
                alert.messageText = "Remove \(conn.displayName) from this workspace?"
                let inOthers = ConnectionStore.shared.workspaces(for: conn.id)
                    .subtracting([WorkspaceStore.shared.activeID])
                    .count
                alert.informativeText = inOthers > 0
                    ? "It will stay in \(inOthers) other workspace\(inOthers == 1 ? "" : "s")."
                    : "This can't be undone."
                if alert.runModal() == .alertFirstButtonReturn {
                    ConnectionStore.shared.remove(conn)
                }
            }
        case .folder(let folder):
            let count = ConnectionStore.shared.connections(in: folder.id).count
            alert.messageText = "Remove folder \(folder.name)?"
            alert.informativeText = count == 0
                ? "The folder is empty."
                : "\(count) connection\(count == 1 ? "" : "s") inside will move back to the root."
            if alert.runModal() == .alertFirstButtonReturn {
                ConnectionStore.shared.removeFolder(folder.id)
            }
        }
    }

    // MARK: - Outline data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if displayMode == .allConnections {
            return item == nil ? allConnections.count : 0
        }
        guard let item = item as? RowItem else {
            return folders.count + rootConnections.count
        }
        if case .folder(let f) = item.row {
            return ConnectionStore.shared.connections(in: f.id).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if displayMode == .allConnections {
            return RowItem(.connection(allConnections[index]))
        }
        if let item = item as? RowItem, case .folder(let f) = item.row {
            let kids = ConnectionStore.shared.connections(in: f.id)
            return RowItem(.connection(kids[index]))
        }
        if index < folders.count {
            return folderItem(for: folders[index].id)
        }
        return RowItem(.connection(rootConnections[index - folders.count]))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard displayMode == .thisWorkspace,
              let item = item as? RowItem else { return false }
        if case .folder = item.row { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn,
              let item = item as? RowItem else { return nil }

        // Workspaces column gets a dedicated cell that draws a row of
        // SF Symbol badges, one per workspace the connection is in.
        if column.identifier.rawValue == "workspaces" {
            let id = NSUserInterfaceItemIdentifier("ws-cell")
            let cell: WorkspaceBadgesCellView =
                (outlineView.makeView(withIdentifier: id, owner: nil) as? WorkspaceBadgesCellView)
                ?? WorkspaceBadgesCellView(reuseID: id)
            switch item.row {
            case .connection(let conn):
                let memberships = ConnectionStore.shared.workspaces(for: conn.id)
                let ordered = WorkspaceStore.shared.workspaces.filter { memberships.contains($0.id) }
                cell.configure(workspaces: ordered)
            case .folder:
                cell.configure(workspaces: [])
            }
            return cell
        }

        // Standard text-with-leading-icon cell for name / userHost / port.
        let id = NSUserInterfaceItemIdentifier("conn-cell")
        let cell: NSTableCellView = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(icon)
            v.imageView = icon
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            v.addSubview(tf)
            v.textField = tf
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()

        // Only the outline column (the name column) needs an icon — other
        // columns are plain text, so hide the image view there.
        let showIcon = (column.identifier.rawValue == "name")
        cell.imageView?.isHidden = !showIcon

        switch item.row {
        case .folder(let folder):
            cell.imageView?.image = NSImage(systemSymbolName: "folder",
                                            accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            switch column.identifier.rawValue {
            case "name":
                cell.textField?.stringValue = folder.name.isEmpty ? "Untitled" : folder.name
                cell.textField?.font = .systemFont(ofSize: 13, weight: .semibold)
            default:
                cell.textField?.stringValue = ""
            }
        case .connection(let connection):
            cell.imageView?.image = NSImage(systemSymbolName: "terminal",
                                            accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 13)
            switch column.identifier.rawValue {
            case "name":     cell.textField?.stringValue = connection.displayName
            case "userHost": cell.textField?.stringValue = "\(connection.user)@\(connection.host)"
            case "port":     cell.textField?.stringValue = String(connection.port)
            default:         cell.textField?.stringValue = ""
            }
        }
        return cell
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Folder placement / row reordering only makes sense in the
        // workspace-scoped view. The global view is a flat list with
        // no folders, so dragging would have no target.
        guard displayMode == .thisWorkspace else { return nil }
        guard let item = item as? RowItem else { return nil }
        let payload: String
        switch item.row {
        case .folder(let f):     payload = "folder:\(f.id.uuidString)"
        case .connection(let c): payload = "connection:\(c.id.uuidString)"
        }
        let p = NSPasteboardItem()
        p.setString(payload, forType: Self.dragPasteboardType)
        return p
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let payload = info.draggingPasteboard.string(forType: Self.dragPasteboardType) else {
            return []
        }
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let _ = UUID(uuidString: parts[1]) else { return [] }
        let kind = parts[0]

        // Folders can only live at the root level.
        if kind == "folder" {
            if item == nil { return .move }
            return []
        }
        // Connections may land at the root (item == nil) or inside any folder.
        if kind == "connection" {
            if item == nil { return .move }
            if let target = item as? RowItem, case .folder = target.row {
                // index == -1 means "on" the folder (default to top); allow it.
                return .move
            }
            return []
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        guard let payload = info.draggingPasteboard.string(forType: Self.dragPasteboardType) else {
            return false
        }
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[1]) else { return false }
        let kind = parts[0]
        let store = ConnectionStore.shared

        if kind == "folder" {
            // Translate root drop index into a folder slot. AppKit gives us
            // an index in the parent's child list — folders come first, so
            // we clamp to [0, folders.count].
            let folderCount = folders.count
            let target = max(0, min(folderCount, index == -1 ? folderCount : index))
            store.moveFolder(uuid, to: target)
            return true
        }

        if kind == "connection" {
            if item == nil {
                // Dropped at root. Root children are [folders..., rootConnections...]
                // so the per-group index is `proposedChildIndex - folders.count`.
                let folderCount = folders.count
                let raw = index == -1 ? rootConnections.count : (index - folderCount)
                let target = max(0, raw)
                store.moveConnection(uuid, toFolder: nil, at: target)
                return true
            }
            if let target = item as? RowItem, case .folder(let folder) = target.row {
                let target = max(0, index == -1 ? 0 : index)
                store.moveConnection(uuid, toFolder: folder.id, at: target)
                return true
            }
        }
        return false
    }
}

// MARK: - Add/Edit sheet

/// Sheet for adding or editing a `SavedConnection`. Lives as a class so the
/// "Use jumphost" checkbox can target an `@objc` method to show/hide the
/// jump-host fields — `NSAlert.accessoryView` doesn't get any other natural
/// owner for that callback.
final class ConnectionEditor: NSObject {
    private let nameField = NSTextField()
    private let userField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let identityField = NSTextField()
    private let folderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let jumphostCheckbox = NSButton(checkboxWithTitle: "Use jumphost",
                                            target: nil, action: nil)
    private let jumpUserField = NSTextField()
    private let jumpHostField = NSTextField()
    private let jumpPortField = NSTextField()
    private var jumpRows: [NSStackView] = []
    /// Tracks `(workspaceID, checkbox)` pairs in display order so save
    /// can collect the user's selection back into a `Set<UUID>`.
    private var workspaceCheckboxes: [(UUID, NSButton)] = []

    private let existing: SavedConnection?
    /// Completion gets the edited connection plus the new set of
    /// workspaces the user wants it to belong to. Caller handles the
    /// store mutations — add vs update + setWorkspaces is the caller's
    /// concern.
    private let completion: (SavedConnection, Set<UUID>) -> Void

    private init(existing: SavedConnection?,
                 completion: @escaping (SavedConnection, Set<UUID>) -> Void) {
        self.existing = existing
        self.completion = completion
        super.init()
    }

    /// Show a sheet to add (when `editing == nil`) or edit a connection.
    static func present(over parent: NSWindow,
                        editing existing: SavedConnection?,
                        completion: @escaping (SavedConnection, Set<UUID>) -> Void) {
        let editor = ConnectionEditor(existing: existing, completion: completion)
        editor.show(over: parent)
    }

    private func show(over parent: NSWindow) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Connection" : "Edit Connection"
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        Self.row(stack, label: "Name", field: nameField, value: existing?.name ?? "")
        Self.row(stack, label: "User", field: userField, value: existing?.user ?? NSUserName())
        Self.row(stack, label: "Host", field: hostField, value: existing?.host ?? "")
        Self.row(stack, label: "Port", field: portField, value: String(existing?.port ?? 22))
        Self.row(stack, label: "Identity file", field: identityField, value: existing?.identityFile ?? "")
        configureFolderPopup(currentID: existing?.folderID)
        Self.popupRow(stack, label: "Folder", popup: folderPopup)

        // "Use jumphost" checkbox — sits flush with the field column so it
        // visually anchors to the bastion-related rows below it.
        jumphostCheckbox.target = self
        jumphostCheckbox.action = #selector(jumphostToggled(_:))
        let usesJump = (existing?.jumpHost?.isEmpty == false)
        jumphostCheckbox.state = usesJump ? .on : .off
        let cbRow = NSStackView()
        cbRow.orientation = .horizontal
        cbRow.spacing = 8
        cbRow.alignment = .centerY
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 100).isActive = true
        cbRow.addArrangedSubview(spacer)
        cbRow.addArrangedSubview(jumphostCheckbox)
        stack.addArrangedSubview(cbRow)

        let juRow = Self.row(stack, label: "Jump user", field: jumpUserField,
                             value: existing?.jumpUser ?? "")
        let jhRow = Self.row(stack, label: "Jump host", field: jumpHostField,
                             value: existing?.jumpHost ?? "")
        let jpRow = Self.row(stack, label: "Jump port", field: jumpPortField,
                             value: String(existing?.jumpPort ?? 22))
        jumpRows = [juRow, jhRow, jpRow]
        applyJumphostVisibility()

        // Workspaces — checkbox per workspace, defaults to the active
        // workspace when adding, or the connection's current
        // memberships when editing. Setting these gives users the
        // "reuse the same connection in two workspaces" path the
        // sidebar / Quick Connect can't expose on their own.
        let initialWorkspaces: Set<UUID>
        if let existing {
            initialWorkspaces = ConnectionStore.shared.workspaces(for: existing.id)
        } else {
            initialWorkspaces = [WorkspaceStore.shared.activeID]
        }
        let wsRow = makeWorkspacesRow(initiallyChecked: initialWorkspaces)
        stack.addArrangedSubview(wsRow)

        // Tall enough that toggling on the jumphost rows doesn't have to
        // resize the alert window — empty space below when off is fine.
        // Bumped to fit the workspaces picker too.
        let perWorkspaceRow: CGFloat = 22
        let baseHeight: CGFloat = 360
        let extra = CGFloat(max(0, WorkspaceStore.shared.workspaces.count - 1)) * perWorkspaceRow
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: baseHeight + extra)
        alert.accessoryView = stack

        alert.beginSheetModal(for: parent) { [self] response in
            // Strong capture of self keeps the editor alive for the duration
            // of the sheet; the closure is released afterwards.
            guard response == .alertFirstButtonReturn else { return }
            let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22
            var connection = existing ?? SavedConnection(name: "", host: "", user: "")
            connection.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.user = userField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.port = port
            let identity = identityField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.identityFile = identity.isEmpty ? nil : identity
            connection.folderID = folderPopup.selectedItem?.representedObject as? UUID

            if jumphostCheckbox.state == .on {
                let jh = jumpHostField.stringValue.trimmingCharacters(in: .whitespaces)
                let ju = jumpUserField.stringValue.trimmingCharacters(in: .whitespaces)
                let jp = Int(jumpPortField.stringValue.trimmingCharacters(in: .whitespaces))
                // Only persist a jump config when both host and user are
                // filled — without either the `-J` arg is invalid.
                if !jh.isEmpty, !ju.isEmpty {
                    connection.jumpHost = jh
                    connection.jumpUser = ju
                    connection.jumpPort = jp
                } else {
                    connection.jumpHost = nil
                    connection.jumpUser = nil
                    connection.jumpPort = nil
                }
            } else {
                connection.jumpHost = nil
                connection.jumpUser = nil
                connection.jumpPort = nil
            }

            guard !connection.host.isEmpty, !connection.user.isEmpty else { return }
            let pickedWorkspaces = Set(workspaceCheckboxes.compactMap { (id, cb) in
                cb.state == .on ? id : nil
            })
            // Guard against orphaning the connection: if the user
            // unchecks every workspace, default back to the active one
            // so the connection still appears somewhere. The Settings
            // page is the only entry that could reach this state.
            let final = pickedWorkspaces.isEmpty
                ? [WorkspaceStore.shared.activeID]
                : pickedWorkspaces
            completion(connection, final)
        }
    }

    /// Build the "Workspaces" picker row — left-aligned label plus a
    /// vertical stack of checkboxes (one per workspace), each labelled
    /// with the workspace's SF Symbol + name. Populates
    /// `workspaceCheckboxes` so save can collect the user's selection.
    private func makeWorkspacesRow(initiallyChecked: Set<UUID>) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8

        let lbl = NSTextField(labelWithString: "Workspaces:")
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 100).isActive = true
        row.addArrangedSubview(lbl)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.widthAnchor.constraint(equalToConstant: 240).isActive = true

        workspaceCheckboxes = []
        for ws in WorkspaceStore.shared.workspaces {
            let cbRow = NSStackView()
            cbRow.orientation = .horizontal
            cbRow.spacing = 6
            cbRow.alignment = .centerY

            let cb = NSButton(checkboxWithTitle: "",
                              target: nil, action: nil)
            cb.state = initiallyChecked.contains(ws.id) ? .on : .off

            let iconView = NSImageView()
            iconView.image = NSImage(systemSymbolName: ws.iconSymbol,
                                     accessibilityDescription: ws.name)
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11,
                                                                       weight: .medium)
            iconView.contentTintColor = .secondaryLabelColor

            let nameLbl = NSTextField(labelWithString: ws.name)
            nameLbl.font = .systemFont(ofSize: 12)

            cbRow.addArrangedSubview(cb)
            cbRow.addArrangedSubview(iconView)
            cbRow.addArrangedSubview(nameLbl)
            list.addArrangedSubview(cbRow)

            workspaceCheckboxes.append((ws.id, cb))
        }

        row.addArrangedSubview(list)
        return row
    }

    @objc private func jumphostToggled(_ sender: NSButton) {
        applyJumphostVisibility()
    }

    private func applyJumphostVisibility() {
        let on = jumphostCheckbox.state == .on
        for row in jumpRows { row.isHidden = !on }
    }

    private func configureFolderPopup(currentID: UUID?) {
        folderPopup.removeAllItems()
        folderPopup.addItem(withTitle: "(no folder)")
        for folder in ConnectionStore.shared.folders {
            folderPopup.addItem(withTitle: folder.name.isEmpty ? "Untitled" : folder.name)
            folderPopup.lastItem?.representedObject = folder.id
        }
        if let currentID,
           let match = folderPopup.itemArray.firstIndex(where: {
               ($0.representedObject as? UUID) == currentID
           }) {
            folderPopup.selectItem(at: match)
        } else {
            folderPopup.selectItem(at: 0)
        }
    }

    @discardableResult
    private static func row(_ stack: NSStackView, label: String,
                            field: NSTextField, value: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let lbl = NSTextField(labelWithString: label + ":")
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 100).isActive = true
        field.stringValue = value
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(field)
        stack.addArrangedSubview(row)
        return row
    }

    @discardableResult
    private static func popupRow(_ stack: NSStackView, label: String,
                                 popup: NSPopUpButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let lbl = NSTextField(labelWithString: label + ":")
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 100).isActive = true
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(popup)
        stack.addArrangedSubview(row)
        return row
    }
}

// MARK: - Folder name sheet

enum FolderNameEditor {
    static func present(over parent: NSWindow,
                        existingName: String?,
                        completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = existingName == nil ? "New Folder" : "Rename Folder"
        alert.addButton(withTitle: existingName == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: existingName ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "Folder name"
        alert.accessoryView = field

        alert.beginSheetModal(for: parent) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            completion(name)
        }
    }
}


// MARK: - Workspace badges cell

/// Custom outline-view cell that renders a horizontal row of small SF
/// Symbol icons — one per workspace the connection belongs to. Used in
/// the `workspaces` column of the Connections settings outline.
final class WorkspaceBadgesCellView: NSTableCellView {
    private let stack = NSStackView()
    private static let badgeSize: CGFloat = 14

    init(reuseID: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuseID
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(workspaces: [Workspace]) {
        // Reuse path: wipe previous badges before building the new set.
        stack.arrangedSubviews.forEach { v in
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: Self.badgeSize - 2,
                                                       weight: .medium)
        for ws in workspaces {
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: ws.iconSymbol,
                               accessibilityDescription: ws.name)?
                .withSymbolConfiguration(symbolConfig)
            iv.contentTintColor = .secondaryLabelColor
            iv.toolTip = ws.name
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: Self.badgeSize).isActive = true
            iv.heightAnchor.constraint(equalToConstant: Self.badgeSize).isActive = true
            stack.addArrangedSubview(iv)
        }
    }
}

