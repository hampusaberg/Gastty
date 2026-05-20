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
        userHostCol.title = "user@host"; userHostCol.width = 220
        outline.addTableColumn(userHostCol)
        let portCol = NSTableColumn(identifier: .init("port"))
        portCol.title = "Port"; portCol.width = 60
        outline.addTableColumn(portCol)

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
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
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
        folders = store.folders
        rootConnections = store.rootConnections
        // Prune cached folder items so we don't carry references to deleted folders.
        let activeIDs = Set(folders.map { $0.id })
        folderItems = folderItems.filter { activeIDs.contains($0.key) }
        outline.reloadData()
        for folder in folders {
            outline.expandItem(folderItem(for: folder.id))
        }
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
        ConnectionEditor.present(over: window!, editing: nil) { conn in
            ConnectionStore.shared.add(conn)
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
            ConnectionEditor.present(over: window!, editing: existing) { conn in
                ConnectionStore.shared.update(conn)
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
            alert.messageText = "Remove \(conn.displayName)?"
            alert.informativeText = "This can't be undone."
            if alert.runModal() == .alertFirstButtonReturn {
                ConnectionStore.shared.remove(conn)
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
        return RowItem(.connection(rootConnections[index - folders.count]))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? RowItem else { return false }
        if case .folder = item.row { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn,
              let item = item as? RowItem else { return nil }
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

    private let existing: SavedConnection?
    private let completion: (SavedConnection) -> Void

    private init(existing: SavedConnection?,
                 completion: @escaping (SavedConnection) -> Void) {
        self.existing = existing
        self.completion = completion
        super.init()
    }

    /// Show a sheet to add (when `editing == nil`) or edit a connection.
    static func present(over parent: NSWindow,
                        editing existing: SavedConnection?,
                        completion: @escaping (SavedConnection) -> Void) {
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

        // Tall enough that toggling on the jumphost rows doesn't have to
        // resize the alert window — empty space below when off is fine.
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 340)
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
            completion(connection)
        }
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
