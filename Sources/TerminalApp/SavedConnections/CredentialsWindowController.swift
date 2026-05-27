import AppKit

/// Window that lists all saved credentials and allows adding, editing,
/// and removing them.
final class CredentialsWindowController: NSWindowController, NSWindowDelegate,
                                          NSTableViewDataSource, NSTableViewDelegate {

    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let toolbar = NSView()
    private let addButton = NSButton()
    private let editButton = NSButton()
    private let removeButton = NSButton()

    private var credentials: [SavedCredential] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Credentials"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        layoutContents()
        refresh()
        NotificationCenter.default.addObserver(self,
            selector: #selector(refresh),
            name: CredentialStore.changedNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Layout

    private func layoutContents() {
        guard let content = window?.contentView else { return }

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"; nameCol.width = 150; nameCol.minWidth = 80

        let userCol = NSTableColumn(identifier: .init("user"))
        userCol.title = "User"; userCol.width = 130; userCol.minWidth = 60

        let identityCol = NSTableColumn(identifier: .init("identity"))
        identityCol.title = "Identity File"; identityCol.width = 180; identityCol.minWidth = 80

        let passwordCol = NSTableColumn(identifier: .init("password"))
        passwordCol.title = "Password"; passwordCol.width = 80; passwordCol.minWidth = 60

        for col in [nameCol, userCol, identityCol, passwordCol] {
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(editSelected(_:))

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)

        for (button, title, action) in [
            (addButton,    "Add",    #selector(add(_:))),
            (editButton,   "Edit",   #selector(editSelected(_:))),
            (removeButton, "Remove", #selector(removeSelected(_:))),
        ] as [(NSButton, String, Selector)] {
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

    // MARK: - Actions

    @objc private func refresh() {
        credentials = CredentialStore.shared.credentials
        table.reloadData()
    }

    @objc private func add(_ sender: Any?) {
        guard let w = window else { return }
        CredentialEditor.present(over: w, editing: nil) { credential, password in
            CredentialStore.shared.add(credential)
            if let password, !password.isEmpty {
                CredentialStore.shared.setPassword(password, for: credential.id)
            }
        }
    }

    @objc private func editSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < credentials.count else { return }
        let existing = credentials[row]
        guard let w = window else { return }
        CredentialEditor.present(over: w, editing: existing) { credential, password in
            CredentialStore.shared.update(credential)
            if let password {
                if password.isEmpty {
                    CredentialStore.shared.deletePassword(for: credential.id)
                } else {
                    CredentialStore.shared.setPassword(password, for: credential.id)
                }
            }
        }
    }

    @objc private func removeSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < credentials.count else { return }
        let cred = credentials[row]
        let alert = NSAlert()
        alert.messageText = "Remove credential \"\(cred.name.isEmpty ? "Unnamed" : cred.name)\"?"
        alert.informativeText = "Connections using this credential will fall back to their own user and identity file settings."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            CredentialStore.shared.remove(cred)
        }
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { credentials.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < credentials.count else { return nil }
        let cred = credentials[row]
        let id = NSUserInterfaceItemIdentifier("cred-cell")
        let cell: NSTableCellView =
            (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                v.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                v.addSubview(tf)
                v.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                ])
                return v
            }()
        switch tableColumn?.identifier.rawValue {
        case "name":     cell.textField?.stringValue = cred.name.isEmpty ? "(unnamed)" : cred.name
        case "user":     cell.textField?.stringValue = cred.user
        case "identity": cell.textField?.stringValue = cred.identityFile ?? ""
        case "password": cell.textField?.stringValue =
            CredentialStore.shared.hasPassword(for: cred.id) ? "●●●●" : ""
        default:         cell.textField?.stringValue = ""
        }
        return cell
    }
}

// MARK: - Add / Edit sheet

/// Sheet for adding or editing a `SavedCredential`.
///
/// Completion delivers the updated credential plus an optional password
/// delta: `nil` = don't touch the stored password; `""` = delete it;
/// any other string = replace it.
final class CredentialEditor: NSObject {

    private let nameField = NSTextField()
    private let userField = NSTextField()
    private let identityField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let clearPasswordButton = NSButton(checkboxWithTitle: "Clear stored password",
                                               target: nil, action: nil)

    private let existing: SavedCredential?
    private let completion: (SavedCredential, String?) -> Void

    private init(existing: SavedCredential?,
                 completion: @escaping (SavedCredential, String?) -> Void) {
        self.existing = existing
        self.completion = completion
        super.init()
    }

    /// Show a sheet to add (when `editing == nil`) or edit a credential.
    static func present(over parent: NSWindow,
                        editing existing: SavedCredential?,
                        completion: @escaping (SavedCredential, String?) -> Void) {
        let editor = CredentialEditor(existing: existing, completion: completion)
        editor.show(over: parent)
    }

    private func show(over parent: NSWindow) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Credential" : "Edit Credential"
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        Self.row(stack, label: "Name", field: nameField,
                 value: existing?.name ?? "", placeholder: "e.g. Work servers")
        Self.row(stack, label: "User", field: userField,
                 value: existing?.user ?? NSUserName(), placeholder: "")
        Self.row(stack, label: "Identity file", field: identityField,
                 value: existing?.identityFile ?? "", placeholder: "~/.ssh/id_ed25519")

        let pwRow = NSStackView()
        pwRow.orientation = .horizontal
        pwRow.spacing = 8
        pwRow.alignment = .centerY
        let pwLabel = NSTextField(labelWithString: "Password:")
        pwLabel.alignment = .right
        pwLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        passwordField.placeholderString = (existing != nil) ? "(leave blank to keep current)" : ""
        passwordField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        pwRow.addArrangedSubview(pwLabel)
        pwRow.addArrangedSubview(passwordField)
        stack.addArrangedSubview(pwRow)

        // "Clear stored password" checkbox — only shown when editing a
        // credential that already has a password in Keychain.
        if let existing, CredentialStore.shared.hasPassword(for: existing.id) {
            clearPasswordButton.state = .off
            let cbRow = NSStackView()
            cbRow.orientation = .horizontal
            cbRow.spacing = 8
            cbRow.alignment = .centerY
            let sp = NSView()
            sp.translatesAutoresizingMaskIntoConstraints = false
            sp.widthAnchor.constraint(equalToConstant: 100).isActive = true
            cbRow.addArrangedSubview(sp)
            cbRow.addArrangedSubview(clearPasswordButton)
            stack.addArrangedSubview(cbRow)
        }

        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 160)
        alert.accessoryView = stack

        alert.beginSheetModal(for: parent) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            var credential = existing ?? SavedCredential(name: "", user: NSUserName())
            credential.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            credential.user = userField.stringValue.trimmingCharacters(in: .whitespaces)
            let identity = identityField.stringValue.trimmingCharacters(in: .whitespaces)
            credential.identityFile = identity.isEmpty ? nil : identity
            guard !credential.user.isEmpty else { return }

            let typed = passwordField.stringValue
            if !typed.isEmpty {
                completion(credential, typed)
            } else if clearPasswordButton.state == .on {
                completion(credential, "")   // empty = delete from Keychain
            } else {
                completion(credential, nil)  // nil = leave Keychain unchanged
            }
        }
    }

    @discardableResult
    private static func row(_ stack: NSStackView, label: String, field: NSTextField,
                            value: String, placeholder: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let lbl = NSTextField(labelWithString: label + ":")
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 100).isActive = true
        field.stringValue = value
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(field)
        stack.addArrangedSubview(row)
        return row
    }
}
