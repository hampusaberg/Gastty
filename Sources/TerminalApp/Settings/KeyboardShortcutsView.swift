import AppKit

/// Settings → Keyboard pane. One row per entry in `ShortcutRegistry`,
/// grouped by category. Each row has:
///
///   - Action label ("Quick Connect…")
///   - A `ShortcutRecorderButton` showing the current binding; click
///     to record a new combo (Esc cancels, Backspace clears).
///   - "Reset" button (only enabled when the binding differs from the
///     default) that restores the default for that one entry.
///
/// A "Restore All Defaults" button at the bottom wipes every override.
final class KeyboardShortcutsView: NSView {

    private let registry = ShortcutRegistry.shared
    private var rowButtons: [String: ShortcutRecorderButton] = [:]
    private var resetButtons: [String: NSButton] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registryChanged),
            name: ShortcutRegistry.changedNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Layout

    private func buildLayout() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        addSubview(scroll)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        // Group entries by category so related actions cluster
        // visually — "Tabs & Windows", "Connections", "View".
        let grouped = Dictionary(grouping: registry.entries, by: { $0.category })
        let orderedCategories = orderedCategoryList(from: grouped.keys)
        for category in orderedCategories {
            stack.addArrangedSubview(makeSectionHeader(category))
            let categoryEntries = grouped[category] ?? []
            for entry in categoryEntries {
                stack.addArrangedSubview(makeRow(for: entry))
            }
        }

        stack.addArrangedSubview(makeFooter())

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            // Pin width so the scroll view's document tracks the
            // visible width — without this, NSStackView lays out at
            // its intrinsic content size and the rows stay at the
            // recorder's natural width instead of stretching.
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    /// Restore the upstream Ghostty section order even after
    /// Dictionary scrambles it. Falls back to alphabetical for any
    /// category not in the canonical list.
    private func orderedCategoryList(from keys: any Collection<String>) -> [String] {
        let canonical = ["Tabs & Windows", "Connections", "View"]
        var ordered = canonical.filter { keys.contains($0) }
        let extras = Set(keys).subtracting(canonical).sorted()
        ordered.append(contentsOf: extras)
        return ordered
    }

    private func makeSectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeRow(for entry: ShortcutEntry) -> NSView {
        let label = NSTextField(labelWithString: entry.menuTitle)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        let recorder = ShortcutRecorderButton(binding: registry.binding(for: entry.id))
        recorder.onCapture = { [weak self] newBinding in
            self?.registry.setBinding(newBinding, for: entry.id)
        }
        recorder.setContentHuggingPriority(.required, for: .horizontal)
        rowButtons[entry.id] = recorder

        let reset = NSButton(
            image: NSImage(systemSymbolName: "arrow.uturn.backward.circle",
                           accessibilityDescription: "Reset to default")!,
            target: self,
            action: #selector(resetClicked(_:))
        )
        reset.bezelStyle = .accessoryBarAction
        reset.isBordered = false
        reset.imageScaling = .scaleProportionallyDown
        reset.identifier = NSUserInterfaceItemIdentifier(entry.id)
        reset.toolTip = "Reset to default (\(entry.default.displayString))"
        reset.isHidden = !registry.isOverridden(entry.id)
        resetButtons[entry.id] = reset

        let row = NSStackView(views: [label, NSView(), recorder, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        // Spacer view between label and recorder so the recorder hugs
        // the right edge regardless of label length.
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        return row
    }

    private func makeFooter() -> NSView {
        let restore = NSButton(
            title: "Restore All Defaults",
            target: self,
            action: #selector(restoreAllClicked(_:))
        )
        restore.bezelStyle = .rounded
        let hint = NSTextField(labelWithString:
            "Tip: click a shortcut to record a new combo. Press Esc to cancel or Delete to clear.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 2

        let stack = NSStackView(views: [restore, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    // MARK: Actions

    @objc private func resetClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        registry.resetBinding(for: id)
    }

    @objc private func restoreAllClicked(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore all shortcuts to defaults?"
        alert.informativeText = "Every custom keyboard shortcut you've set will revert."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            registry.resetAll()
        }
    }

    @objc private func registryChanged() {
        // Refresh every row's displayed binding + reset-button visibility.
        for entry in registry.entries {
            let binding = registry.binding(for: entry.id)
            rowButtons[entry.id]?.binding = binding
            resetButtons[entry.id]?.isHidden = !registry.isOverridden(entry.id)
        }
    }
}

// MARK: - Recorder button

/// Button that displays the current keyboard shortcut. Clicking puts
/// it into "recording" mode where the next key event captured becomes
/// the new binding. Esc cancels recording; Delete/Backspace clears
/// the binding entirely.
///
/// While recording we install a local NSEvent monitor that consumes
/// the keypress before it reaches the menu system — without this,
/// recording ⌘W would close the window before we saw the keystroke.
final class ShortcutRecorderButton: NSButton {

    var binding: ShortcutBinding {
        didSet { refreshTitle() }
    }
    var onCapture: ((ShortcutBinding) -> Void)?

    private var recording = false
    private var keyMonitor: Any?

    init(binding: ShortcutBinding) {
        self.binding = binding
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording(_:))
        widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func refreshTitle() {
        title = recording ? "Press shortcut…" : binding.displayString
        contentTintColor = recording ? .systemBlue : .labelColor
    }

    @objc private func toggleRecording(_ sender: Any?) {
        recording.toggle()
        refreshTitle()
        if recording {
            startMonitor()
        } else {
            stopMonitor()
        }
    }

    private func startMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleEvent(event)
            return nil   // swallow — don't let the menu / responder chain see it
        }
    }

    private func stopMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        recording = false
        refreshTitle()
    }

    /// Translate a keyDown event into a `ShortcutBinding` and commit.
    /// Special cases:
    ///   - Esc → cancel recording, leave binding unchanged
    ///   - Delete / Backspace alone → clear binding to unbound
    ///   - Anything else → treat as the new combo
    private func handleEvent(_ event: NSEvent) {
        // flagsChanged doesn't give us a key — wait for keyDown.
        guard event.type == .keyDown else { return }

        // Esc (keyCode 53) cancels.
        if event.keyCode == 53 {
            stopMonitor()
            return
        }
        // Delete / Backspace (keyCode 51) with no modifiers clears.
        if event.keyCode == 51, event.modifierFlags
            .intersection([.command, .shift, .option, .control]).isEmpty {
            binding = .unbound
            onCapture?(.unbound)
            stopMonitor()
            return
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              !chars.isEmpty else {
            return
        }
        // Require at least one of cmd/shift/opt/ctrl — bare letter
        // keys aren't useful as menu shortcuts and would shadow
        // typing in surfaces.
        let mods = ShortcutModifiers(eventFlags: event.modifierFlags
            .intersection([.command, .shift, .option, .control]))
        guard !mods.isEmpty else { return }

        let captured = ShortcutBinding(key: chars, mods: mods)
        binding = captured
        onCapture?(captured)
        stopMonitor()
    }
}
