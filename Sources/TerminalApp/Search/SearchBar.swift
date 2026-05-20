import AppKit
import GhosttyKit

/// Inline find bar — slides in at the top of a surface area when ⌘F is
/// pressed. Drives libghostty's `search:<needle>` and `end_search` binding
/// actions so the terminal renderer highlights matches.
final class SearchBar: NSView, NSTextFieldDelegate {

    private let searchField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    weak var surface: SurfaceHostView?

    var total: Int = 0 { didSet { refreshCount() } }
    var selected: Int = 0 { didSet { refreshCount() } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor

        searchField.placeholderString = "Find in terminal"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.bezelStyle = .roundedBezel
        addSubview(searchField)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        // Previous → down chevron, next → up chevron (per user's spatial
        // preference; left/right felt wrong for a list of matches).
        configure(button: prevButton, symbol: "chevron.down", action: #selector(findPrevious(_:)))
        configure(button: nextButton, symbol: "chevron.up", action: #selector(findNext(_:)))
        configure(button: closeButton, symbol: "xmark", action: #selector(close(_:)))

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 200),

            countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(equalToConstant: 64),

            prevButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 22),
            prevButton.heightAnchor.constraint(equalToConstant: 22),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 22),
            nextButton.heightAnchor.constraint(equalToConstant: 22),

            closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
    }

    private func refreshCount() {
        if total == 0 {
            countLabel.stringValue = searchField.stringValue.isEmpty ? "" : "No results"
        } else {
            countLabel.stringValue = "\(selected + 1) of \(total)"
        }
    }

    func present(over surface: SurfaceHostView, initialQuery: String? = nil) {
        self.surface = surface
        searchField.stringValue = initialQuery ?? ""
        total = 0
        selected = 0
        refreshCount()
        isHidden = false
        window?.makeFirstResponder(searchField)
        sendSearchAction(needle: searchField.stringValue)
    }

    func dismiss() {
        if let surface = surface?.surface {
            invokeBindingAction("end_search", on: surface)
        }
        isHidden = true
        surface = nil
        searchField.stringValue = ""
        total = 0
        selected = 0
    }

    // MARK: - Driving libghostty

    private func sendSearchAction(needle: String) {
        guard let s = surface?.surface else { return }
        invokeBindingAction("search:\(needle)", on: s)
    }

    private func invokeBindingAction(_ name: String, on surface: ghostty_surface_t) {
        let len = name.lengthOfBytes(using: .utf8)
        _ = ghostty_surface_binding_action(surface, name, UInt(len))
    }

    // MARK: - Field events

    func controlTextDidChange(_ obj: Notification) {
        sendSearchAction(needle: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            findNext(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            findPrevious(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - Navigation

    @objc private func findNext(_ sender: Any?) {
        guard let surface = surface?.surface else { return }
        invokeBindingAction("navigate_search:next", on: surface)
    }
    @objc private func findPrevious(_ sender: Any?) {
        guard let surface = surface?.surface else { return }
        invokeBindingAction("navigate_search:previous", on: surface)
    }
    @objc private func close(_ sender: Any?) {
        dismiss()
    }
}
