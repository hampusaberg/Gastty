import AppKit

/// Manage saved SSH connections: list, add, edit, delete.
final class ConnectionsWindowController: NSWindowController, NSWindowDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let toolbar = NSView()
    private let addButton = NSButton()
    private let editButton = NSButton()
    private let removeButton = NSButton()
    private let dataSource = ConnectionsTableSource()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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

        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(editSelected(_:))

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"; nameCol.width = 160
        tableView.addTableColumn(nameCol)
        let userHostCol = NSTableColumn(identifier: .init("userHost"))
        userHostCol.title = "user@host"; userHostCol.width = 220
        tableView.addTableColumn(userHostCol)
        let portCol = NSTableColumn(identifier: .init("port"))
        portCol.title = "Port"; portCol.width = 60
        tableView.addTableColumn(portCol)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)

        for (button, title, action) in [
            (addButton,    "Add",     #selector(add(_:))),
            (editButton,   "Edit",    #selector(editSelected(_:))),
            (removeButton, "Remove",  #selector(removeSelected(_:))),
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
            editButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            editButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 6),
            removeButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])
    }

    @objc private func refresh() {
        dataSource.connections = ConnectionStore.shared.connections
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func add(_ sender: Any?) {
        ConnectionEditor.present(over: window!, editing: nil) { conn in
            ConnectionStore.shared.add(conn)
        }
    }

    @objc private func editSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard dataSource.connections.indices.contains(row) else { return }
        let existing = dataSource.connections[row]
        ConnectionEditor.present(over: window!, editing: existing) { conn in
            ConnectionStore.shared.update(conn)
        }
    }

    @objc private func removeSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard dataSource.connections.indices.contains(row) else { return }
        let conn = dataSource.connections[row]
        let alert = NSAlert()
        alert.messageText = "Remove \(conn.displayName)?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            ConnectionStore.shared.remove(conn)
        }
    }

}

// MARK: - Table source

final class ConnectionsTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var connections: [SavedConnection] = []

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, connections.indices.contains(row) else { return nil }
        let connection = connections[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf)
            v.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()
        switch column.identifier.rawValue {
        case "name":     cell.textField?.stringValue = connection.name
        case "userHost": cell.textField?.stringValue = "\(connection.user)@\(connection.host)"
        case "port":     cell.textField?.stringValue = String(connection.port)
        default:         cell.textField?.stringValue = ""
        }
        return cell
    }
}

// MARK: - Add/Edit sheet

enum ConnectionEditor {
    /// Show a sheet to add (when `editing == nil`) or edit a connection.
    static func present(over parent: NSWindow,
                        editing existing: SavedConnection?,
                        completion: @escaping (SavedConnection) -> Void) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Connection" : "Edit Connection"
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 180)

        let nameField     = labeledField(stack, label: "Name",          value: existing?.name ?? "")
        let userField     = labeledField(stack, label: "User",          value: existing?.user ?? NSUserName())
        let hostField     = labeledField(stack, label: "Host",          value: existing?.host ?? "")
        let portField     = labeledField(stack, label: "Port",          value: String(existing?.port ?? 22))
        let identityField = labeledField(stack, label: "Identity file", value: existing?.identityFile ?? "")

        alert.accessoryView = stack
        alert.beginSheetModal(for: parent) { response in
            guard response == .alertFirstButtonReturn else { return }
            let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 22
            var connection = existing ?? SavedConnection(name: "", host: "", user: "")
            connection.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.user = userField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.port = port
            let identity = identityField.stringValue.trimmingCharacters(in: .whitespaces)
            connection.identityFile = identity.isEmpty ? nil : identity
            guard !connection.host.isEmpty, !connection.user.isEmpty else { return }
            completion(connection)
        }
    }

    private static func labeledField(_ stack: NSStackView, label: String, value: String) -> NSTextField {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let lbl = NSTextField(labelWithString: label + ":")
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let tf = NSTextField(string: value)
        tf.widthAnchor.constraint(equalToConstant: 200).isActive = true
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(tf)
        stack.addArrangedSubview(row)
        return tf
    }
}
