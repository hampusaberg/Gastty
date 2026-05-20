import AppKit

/// Settings panel — single page for now (Appearance). Every control writes
/// directly to `SettingsStore.shared`, which generates `runtime.conf` and
/// triggers `GhosttyRuntime.reloadConfig()` so changes appear immediately
/// in every open tab.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let fontFamilyField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let fontSizeField = NSTextField()
    private let cursorPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let opacitySlider = NSSlider()
    private let opacityLabel = NSTextField(labelWithString: "100%")
    private let blurSegments = NSSegmentedControl(
        labels: ["Off", "Light", "Medium", "Strong"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildLayout()
        loadFromStore()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 12

        // Font family
        fontFamilyField.placeholderString = "default"
        fontFamilyField.target = self
        fontFamilyField.action = #selector(fontFamilyChanged(_:))
        grid.addRow(with: [NSTextField(labelWithString: "Font family:"), fontFamilyField])

        // Font size
        fontSizeStepper.minValue = 8
        fontSizeStepper.maxValue = 32
        fontSizeStepper.increment = 1
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepperChanged(_:))
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeFieldChanged(_:))
        fontSizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let sizeRow = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4
        grid.addRow(with: [NSTextField(labelWithString: "Font size:"), sizeRow])

        // Cursor
        cursorPopup.target = self
        cursorPopup.action = #selector(cursorChanged(_:))
        for style in AppSettings.CursorStyle.allCases {
            cursorPopup.addItem(withTitle: style.rawValue.capitalized)
        }
        grid.addRow(with: [NSTextField(labelWithString: "Cursor:"), cursorPopup])

        // Theme
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        themePopup.addItem(withTitle: "(none)")
        for name in availableThemes() {
            themePopup.addItem(withTitle: name)
        }
        grid.addRow(with: [NSTextField(labelWithString: "Theme:"), themePopup])

        // Opacity — extended down to 20% so the user can really see through
        // when they want to. Lower than that and the text is hard to read.
        opacitySlider.minValue = 0.2
        opacitySlider.maxValue = 1.0
        opacitySlider.numberOfTickMarks = 9
        opacitySlider.allowsTickMarkValuesOnly = false
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacityLabel.alignment = .right
        opacityLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let opacityRow = NSStackView(views: [opacitySlider, opacityLabel])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8
        opacitySlider.widthAnchor.constraint(equalToConstant: 280).isActive = true
        grid.addRow(with: [NSTextField(labelWithString: "Opacity:"), opacityRow])

        // Blur — discrete segmented buttons. NSVisualEffectView only exposes
        // a handful of materials, so a continuous slider was a fake range.
        blurSegments.target = self
        blurSegments.action = #selector(blurChanged(_:))
        blurSegments.segmentDistribution = .fillEqually
        blurSegments.widthAnchor.constraint(equalToConstant: 280).isActive = true
        grid.addRow(with: [NSTextField(labelWithString: "Blur:"), blurSegments])

        for column in 0..<grid.numberOfColumns {
            grid.column(at: column).xPlacement = column == 0 ? .trailing : .leading
        }

        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
        ])
    }

    private func loadFromStore() {
        let s = SettingsStore.shared.settings
        fontFamilyField.stringValue = s.fontFamily
        fontSizeStepper.doubleValue = s.fontSize
        fontSizeField.stringValue = String(Int(s.fontSize))
        cursorPopup.selectItem(withTitle: s.cursorStyle.rawValue.capitalized)
        themePopup.selectItem(withTitle: s.theme.isEmpty ? "(none)" : s.theme)
        opacitySlider.doubleValue = s.backgroundOpacity
        opacityLabel.stringValue = "\(Int(s.backgroundOpacity * 100))%"
        blurSegments.selectedSegment = Self.segmentIndex(for: s.blurLevel)
    }

    private static func segmentIndex(for level: AppSettings.BlurLevel) -> Int {
        switch level {
        case .off:    return 0
        case .light:  return 1
        case .medium: return 2
        case .strong: return 3
        }
    }

    private static func blurLevel(forSegment idx: Int) -> AppSettings.BlurLevel {
        switch idx {
        case 1:  return .light
        case 2:  return .medium
        case 3:  return .strong
        default: return .off
        }
    }

    // MARK: - Themes shown in the picker
    //
    // libghostty bundles 500+ themes via the resources directory, but we
    // intentionally show a small curated list — the ones people actually
    // reach for. Power users can still set `theme = Something Else` in
    // `~/.config/ghostty/config` and libghostty will find it.

    private static let recommendedThemes: [String] = [
        "Atom One Dark",
        "Atom One Light",
        "Catppuccin Frappe",
        "Catppuccin Latte",
        "Catppuccin Macchiato",
        "Catppuccin Mocha",
        "Dracula",
        "Dracula+",
        "Gruvbox Dark",
        "Gruvbox Light",
        "Monokai Classic",
        "Monokai Pro",
        "Nord",
        "Solarized Dark Patched",
        "iTerm2 Solarized Dark",
        "iTerm2 Solarized Light",
        "TokyoNight",
        "TokyoNight Storm",
    ]

    private func availableThemes() -> [String] {
        // Filter the curated list down to whatever the bundle actually has
        // (so a typo in our list doesn't show a broken entry).
        guard let resPath = Bundle.main.resourcePath else { return [] }
        let themesDir = (resPath as NSString).appendingPathComponent("ghostty/themes")
        let fm = FileManager.default
        return Self.recommendedThemes.filter { name in
            fm.fileExists(atPath: (themesDir as NSString).appendingPathComponent(name))
        }
    }

    // MARK: - Actions

    @objc private func fontFamilyChanged(_ sender: Any?) {
        SettingsStore.shared.update { $0.fontFamily = fontFamilyField.stringValue }
    }

    @objc private func fontSizeStepperChanged(_ sender: Any?) {
        let size = fontSizeStepper.doubleValue
        fontSizeField.stringValue = String(Int(size))
        SettingsStore.shared.update { $0.fontSize = size }
    }

    @objc private func fontSizeFieldChanged(_ sender: Any?) {
        let value = Double(fontSizeField.stringValue) ?? 13
        let clamped = max(8, min(32, value))
        fontSizeStepper.doubleValue = clamped
        SettingsStore.shared.update { $0.fontSize = clamped }
    }

    @objc private func cursorChanged(_ sender: Any?) {
        let raw = cursorPopup.titleOfSelectedItem?.lowercased() ?? "bar"
        if let style = AppSettings.CursorStyle(rawValue: raw) {
            SettingsStore.shared.update { $0.cursorStyle = style }
        }
    }

    @objc private func themeChanged(_ sender: Any?) {
        let title = themePopup.titleOfSelectedItem ?? "(none)"
        SettingsStore.shared.update { $0.theme = title == "(none)" ? "" : title }
    }

    @objc private func opacityChanged(_ sender: Any?) {
        let value = opacitySlider.doubleValue
        opacityLabel.stringValue = "\(Int(value * 100))%"
        SettingsStore.shared.update { $0.backgroundOpacity = value }
    }

    @objc private func blurChanged(_ sender: Any?) {
        let level = Self.blurLevel(forSegment: blurSegments.selectedSegment)
        SettingsStore.shared.update { $0.blurLevel = level }
    }
}
