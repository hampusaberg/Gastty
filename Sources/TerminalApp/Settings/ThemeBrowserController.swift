import AppKit

/// Searchable modal sheet for picking from any of the 512 bundled
/// themes. Reusable from both the Settings window and the onboarding
/// flow — `present(over:current:completion:)` opens it as a sheet on
/// the given parent window and calls back with the picked theme name
/// (or `nil` if cancelled).
///
/// The row UI shows each theme's name plus a small preview swatch
/// (background, plus a foreground line and an accent line) so the user
/// can browse visually instead of just by name. Search is plain
/// substring match on the name.
final class ThemeBrowserController: NSWindowController,
                                     NSTableViewDataSource,
                                     NSTableViewDelegate,
                                     NSSearchFieldDelegate,
                                     NSWindowDelegate {

    /// Sentinel row used to represent "no theme — use Ghostty's default."
    /// We map this to the empty string when returning from the picker so
    /// it round-trips with `AppSettings.theme`.
    private static let defaultThemeRow = "Default (no theme)"

    private let onPick: (String?) -> Void
    private let initialTheme: String

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let useButton = NSButton(title: "Use Theme",
                                     target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel",
                                        target: nil, action: nil)

    private var allRows: [String] = []
    private var filteredRows: [String] = []
    /// Set to true the moment `onPick` fires so the windowWillClose
    /// fallback doesn't double-invoke it.
    private var didCommit = false

    // MARK: - Presentation

    /// Open the browser as a sheet on `parent`. The completion fires with
    /// the picked theme (empty string = "no theme") or `nil` when the
    /// user cancels.
    static func present(over parent: NSWindow,
                        current: String,
                        completion: @escaping (String?) -> Void) {
        let controller = ThemeBrowserController(current: current,
                                                completion: completion)
        if let window = controller.window {
            parent.beginSheet(window) { _ in
                // Keep the controller alive until the sheet ends — the
                // closure capture handles that.
                _ = controller
            }
        }
    }

    // MARK: - Init

    private init(current: String, completion: @escaping (String?) -> Void) {
        self.initialTheme = current
        self.onPick = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Choose a Theme"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        layoutContents()
        loadData()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func layoutContents() {
        guard let content = window?.contentView else { return }

        searchField.placeholderString = "Search themes…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleUse(_:))
        tableView.allowsMultipleSelection = false
        let col = NSTableColumn(identifier: .init("theme"))
        col.title = ""
        tableView.addTableColumn(col)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel(_:))
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancelButton)

        useButton.bezelStyle = .rounded
        useButton.target = self
        useButton.action = #selector(handleUse(_:))
        useButton.keyEquivalent = "\r" // Enter
        useButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(useButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: useButton.topAnchor, constant: -12),

            useButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            useButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            cancelButton.trailingAnchor.constraint(equalTo: useButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func loadData() {
        var rows = [Self.defaultThemeRow]
        rows.append(contentsOf: ThemeRepository.allThemes())
        allRows = rows
        filteredRows = rows
        tableView.reloadData()
        selectInitial()
    }

    private func selectInitial() {
        let target: String
        if initialTheme.isEmpty {
            target = Self.defaultThemeRow
        } else {
            target = initialTheme
        }
        if let idx = filteredRows.firstIndex(of: target) {
            tableView.selectRowIndexes([idx], byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        } else if !filteredRows.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filteredRows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let name = filteredRows[row]
        let id = NSUserInterfaceItemIdentifier("theme-row")
        let cell: ThemeRowView = (tableView.makeView(withIdentifier: id, owner: nil) as? ThemeRowView) ?? {
            let v = ThemeRowView()
            v.identifier = id
            return v
        }()
        if name == Self.defaultThemeRow {
            cell.configureAsDefault(label: name)
        } else {
            cell.configure(name: name, colors: ThemeRepository.colors(for: name))
        }
        return cell
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        let q = searchField.stringValue
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            filteredRows = allRows
        } else {
            filteredRows = allRows.filter { $0.lowercased().contains(q) }
        }
        tableView.reloadData()
        if !filteredRows.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            advanceSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            advanceSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            handleUse(nil); return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleCancel(nil); return true
        default:
            return false
        }
    }

    private func advanceSelection(by delta: Int) {
        guard !filteredRows.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = max(0, min(filteredRows.count - 1, current + delta))
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Commit / cancel

    @objc private func handleUse(_ sender: Any?) {
        guard tableView.selectedRow >= 0,
              tableView.selectedRow < filteredRows.count else {
            handleCancel(nil)
            return
        }
        let row = filteredRows[tableView.selectedRow]
        let value = (row == Self.defaultThemeRow) ? "" : row
        commit(picked: value)
    }

    @objc private func handleCancel(_ sender: Any?) {
        commit(picked: nil)
    }

    private func commit(picked: String?) {
        guard !didCommit else { closeWindow(); return }
        didCommit = true
        onPick(picked)
        closeWindow()
    }

    private func closeWindow() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Catches close paths that bypass our buttons (red X, ⌘W via the
        // sheet) and reports a cancel.
        if !didCommit {
            didCommit = true
            onPick(nil)
        }
    }
}

// MARK: - Row view

private final class ThemeRowView: NSTableCellView {
    private let swatchContainer = NSView()
    private let bgFill = NSView()
    private let fgLine = NSView()
    private let accentLine = NSView()
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setup() {
        swatchContainer.translatesAutoresizingMaskIntoConstraints = false
        swatchContainer.wantsLayer = true
        swatchContainer.layer?.cornerRadius = 5
        swatchContainer.layer?.masksToBounds = true
        swatchContainer.layer?.borderWidth = 1
        swatchContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(swatchContainer)

        bgFill.translatesAutoresizingMaskIntoConstraints = false
        bgFill.wantsLayer = true
        swatchContainer.addSubview(bgFill)

        fgLine.translatesAutoresizingMaskIntoConstraints = false
        fgLine.wantsLayer = true
        fgLine.layer?.cornerRadius = 1
        swatchContainer.addSubview(fgLine)

        accentLine.translatesAutoresizingMaskIntoConstraints = false
        accentLine.wantsLayer = true
        accentLine.layer?.cornerRadius = 1
        swatchContainer.addSubview(accentLine)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        textField = nameLabel

        NSLayoutConstraint.activate([
            swatchContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            swatchContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatchContainer.widthAnchor.constraint(equalToConstant: 72),
            swatchContainer.heightAnchor.constraint(equalToConstant: 36),

            bgFill.topAnchor.constraint(equalTo: swatchContainer.topAnchor),
            bgFill.leadingAnchor.constraint(equalTo: swatchContainer.leadingAnchor),
            bgFill.trailingAnchor.constraint(equalTo: swatchContainer.trailingAnchor),
            bgFill.bottomAnchor.constraint(equalTo: swatchContainer.bottomAnchor),

            fgLine.leadingAnchor.constraint(equalTo: swatchContainer.leadingAnchor, constant: 8),
            fgLine.widthAnchor.constraint(equalToConstant: 40),
            fgLine.heightAnchor.constraint(equalToConstant: 2),
            fgLine.centerYAnchor.constraint(equalTo: swatchContainer.centerYAnchor, constant: -5),

            accentLine.leadingAnchor.constraint(equalTo: swatchContainer.leadingAnchor, constant: 8),
            accentLine.widthAnchor.constraint(equalToConstant: 24),
            accentLine.heightAnchor.constraint(equalToConstant: 2),
            accentLine.centerYAnchor.constraint(equalTo: swatchContainer.centerYAnchor, constant: 4),

            nameLabel.leadingAnchor.constraint(equalTo: swatchContainer.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(name: String, colors: ThemeRepository.Colors) {
        nameLabel.stringValue = name
        bgFill.layer?.backgroundColor = colors.background.cgColor
        fgLine.layer?.backgroundColor =
            (colors.foreground.withAlphaComponent(0.85)).cgColor
        accentLine.layer?.backgroundColor =
            (colors.accent ?? colors.foreground.withAlphaComponent(0.5)).cgColor
        swatchContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        fgLine.isHidden = false
        accentLine.isHidden = false
    }

    func configureAsDefault(label: String) {
        nameLabel.stringValue = label
        bgFill.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        fgLine.isHidden = true
        accentLine.isHidden = true
        swatchContainer.layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
