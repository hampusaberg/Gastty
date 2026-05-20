import AppKit

/// One tab in the custom tab bar.
///
/// Layout: [title NSTextField | × NSButton]
/// - Click anywhere to activate.
/// - Double-click the title to rename (NSTextField becomes editable).
/// - Click × to close.
/// - Right-click opens a context menu (Rename / Close / Duplicate).
/// - Click-and-drag horizontally to reorder.
///
/// IMPORTANT: with `.fullSizeContentView` on the host window the tab bar
/// sits in the titlebar zone, where AppKit normally claims mouseDown for
/// window-drag. To win the race we consume the entire mouseDown→mouseUp
/// sequence inside an `NSWindow.nextEvent(matching:)` tracking loop instead
/// of relying on gesture recognizers + `mouseDownCanMoveWindow`. The override
/// stays as belt-and-braces.
final class TabItemView: NSView, NSTextFieldDelegate {

    weak var tabBar: TabBarView?
    let session: Session

    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let backgroundLayer = CALayer()

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    init(session: Session, tabBar: TabBarView) {
        self.session = session
        self.tabBar = tabBar
        super.init(frame: .zero)
        wantsLayer = true
        layer = backgroundLayer
        backgroundLayer.cornerRadius = 6
        backgroundLayer.masksToBounds = true

        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.font = .systemFont(ofSize: 12)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.stringValue = session.title
        titleField.delegate = self
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        closeButton.bezelStyle = .helpButton
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Always-false: prevents AppKit's title-bar drag from interpreting a
    // tap on the tab as a window-move grab.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Hard-pin our intrinsic height so NSStackView's `.fill` / `.gravityAreas`
    /// distributions can't stretch us. Width stays flexible — horizontal
    /// mode wants equal widths, vertical mode pins to the bar width.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    /// Reflect the latest session title (called after a rename elsewhere).
    func refreshTitle() {
        if !titleField.isEditable {
            titleField.stringValue = session.title
        }
    }

    private func updateAppearance() {
        backgroundLayer.backgroundColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.05).cgColor
        titleField.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    // MARK: - Mouse handling (single mouseDown consumes the whole sequence)

    private static let dragThreshold: CGFloat = 6

    /// Middle-click (mouse-wheel button) closes the tab — standard browser
    /// behavior. NSEvent gives left=0, right=1, middle=2 for `buttonNumber`.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            tabBar?.close(session: session)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Double-click → inline rename.
        if event.clickCount == 2 {
            beginEdit(nil)
            return
        }

        let startInWindow = event.locationInWindow
        var didDrag = false

        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        while let next = window?.nextEvent(matching: mask) {
            switch next.type {
            case .leftMouseDragged:
                let curr = next.locationInWindow
                if !didDrag {
                    let dx = curr.x - startInWindow.x
                    if abs(dx) < Self.dragThreshold { continue }
                    didDrag = true
                    if tabBar?.activeSession?.id != session.id {
                        tabBar?.activate(session: session)
                    }
                    tabBar?.beginDrag(self, mouseLocationInWindow: startInWindow)
                }
                tabBar?.updateDrag(mouseLocationInWindow: curr)

            case .leftMouseUp:
                if didDrag {
                    tabBar?.endDrag()
                } else {
                    tabBar?.activate(session: session)
                }
                return

            default:
                continue
            }
        }
    }

    // MARK: - Editing

    @objc private func close(_ sender: Any?) {
        tabBar?.close(session: session)
    }

    @objc private func duplicate(_ sender: Any?) {
        tabBar?.duplicate(session: session)
    }

    @objc private func beginEdit(_ sender: Any?) {
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.drawsBackground = true
        titleField.backgroundColor = .textBackgroundColor
        titleField.isBordered = true
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    private func endEdit(commit: Bool) {
        if commit {
            let new = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !new.isEmpty {
                session.title = new
                session.titleLocked = true
            }
        }
        titleField.stringValue = session.title
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.isBordered = false
        window?.makeFirstResponder(tabBar?.activeSession?.surfaceView)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endEdit(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEdit(commit: false)
            return true
        }
        return false
    }

    // MARK: - Right-click context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let rename = menu.addItem(withTitle: "Rename Tab", action: #selector(beginEdit(_:)), keyEquivalent: "")
        rename.target = self
        let dup = menu.addItem(withTitle: "Duplicate Tab", action: #selector(duplicate(_:)), keyEquivalent: "")
        dup.target = self
        menu.addItem(.separator())
        let closeItem = menu.addItem(withTitle: "Close Tab", action: #selector(close(_:)), keyEquivalent: "")
        closeItem.target = self
        return menu
    }
}
