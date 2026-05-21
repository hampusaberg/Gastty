import AppKit

/// Sheet for creating or renaming a workspace. Name field + a 6×4 grid
/// of SF Symbol icon tiles (the curated `WorkspaceIconCatalog.all`
/// list). Used by `WorkspaceSwitcherView` when the user picks
/// "New Workspace…" or "Rename Current Workspace…".
///
/// Kept as a class (rather than the enum-with-static-methods pattern
/// the other sheets use) because the icon picker needs to update
/// selection state across many tile views on click — easier with
/// instance methods than juggling captures.
final class WorkspaceEditor: NSObject {

    /// Static entry points so callers don't have to manage the editor
    /// instance themselves. The instance is captured by the modal
    /// completion handler and released when the sheet ends.

    static func presentNew(over parent: NSWindow,
                           completion: @escaping (_ name: String, _ icon: String) -> Void) {
        let editor = WorkspaceEditor(existingName: nil,
                                     existingIcon: WorkspaceIconCatalog.defaultIcon,
                                     completion: completion)
        editor.show(over: parent)
    }

    static func presentEdit(over parent: NSWindow,
                            existing: Workspace,
                            completion: @escaping (_ name: String, _ icon: String) -> Void) {
        let editor = WorkspaceEditor(existingName: existing.name,
                                     existingIcon: existing.iconSymbol,
                                     completion: completion)
        editor.show(over: parent)
    }

    // MARK: - State

    private let existingName: String?
    private var selectedIcon: String
    private let completion: (String, String) -> Void
    private let nameField = NSTextField()
    private var tiles: [IconTileView] = []

    private init(existingName: String?,
                 existingIcon: String,
                 completion: @escaping (String, String) -> Void) {
        self.existingName = existingName
        self.selectedIcon = existingIcon
        self.completion = completion
        super.init()
    }

    // MARK: - Layout

    private func show(over parent: NSWindow) {
        let alert = NSAlert()
        let isEdit = existingName != nil
        alert.messageText = isEdit ? "Edit Workspace" : "New Workspace"
        alert.addButton(withTitle: isEdit ? "Save" : "Create")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 280)

        // Name row
        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.spacing = 10
        nameRow.alignment = .centerY
        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        nameField.stringValue = existingName ?? ""
        nameField.placeholderString = "e.g. Work, Homelab, Personal"
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        nameRow.addArrangedSubview(nameLabel)
        nameRow.addArrangedSubview(nameField)
        stack.addArrangedSubview(nameRow)
        stack.setCustomSpacing(18, after: nameRow)

        // Icon picker label
        let iconHeader = NSTextField(labelWithString: "ICON")
        iconHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        iconHeader.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(iconHeader)
        stack.setCustomSpacing(6, after: iconHeader)

        // Icon grid — nested NSStackViews. NSGridView's automatic
        // column-width equalisation produced inconsistent gaps with
        // these uniformly-sized tiles, so we lay it out by hand: a
        // vertical stack of horizontal rows, each with `cols` tiles
        // and a fixed inter-tile spacing. Predictable, no surprises.
        tiles = []
        let cols = 6
        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = 6

        var currentRow: NSStackView? = nil
        for (idx, symbol) in WorkspaceIconCatalog.all.enumerated() {
            if idx % cols == 0 {
                let r = NSStackView()
                r.orientation = .horizontal
                r.spacing = 6
                r.alignment = .centerY
                currentRow = r
                gridStack.addArrangedSubview(r)
            }
            let tile = IconTileView(symbol: symbol,
                                    isSelected: symbol == selectedIcon) { [weak self] picked in
                guard let self else { return }
                self.selectedIcon = picked
                self.tiles.forEach { $0.refresh(selected: picked) }
            }
            tiles.append(tile)
            currentRow?.addArrangedSubview(tile)
        }
        stack.addArrangedSubview(gridStack)

        alert.accessoryView = stack
        alert.beginSheetModal(for: parent) { [self] response in
            _ = self  // hold self until the modal ends
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            completion(name, selectedIcon)
        }
    }
}

// MARK: - Icon tile

private final class IconTileView: NSView {
    private let symbol: String
    private let onPick: (String) -> Void
    private let bg = NSView()
    private let icon = NSImageView()

    init(symbol: String, isSelected: Bool, onPick: @escaping (String) -> Void) {
        self.symbol = symbol
        self.onPick = onPick
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.borderWidth = 1
        addSubview(bg)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = .labelColor
        addSubview(icon)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 36),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        refresh(selected: isSelected ? symbol : "")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh(selected: String) {
        let isOn = (selected == symbol)
        bg.layer?.backgroundColor = (isOn
            ? NSColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 0.2)
            : NSColor.clear).cgColor
        bg.layer?.borderColor = (isOn
            ? NSColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1)
            : NSColor.separatorColor.withAlphaComponent(0.5)).cgColor
        bg.layer?.borderWidth = isOn ? 2 : 1
        icon.contentTintColor = isOn
            ? NSColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1)
            : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        onPick(symbol)
    }
}
