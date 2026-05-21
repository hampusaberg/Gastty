import AppKit

/// First-run onboarding flow. Walks the user through theme selection,
/// recommended chrome settings, and the keybindings worth learning, then
/// flips `AppSettings.hasCompletedOnboarding` so it never shows again.
///
/// Visual style:
///   - Borderless `.fullSizeContentView` window
///   - Behind-window blur via `NSVisualEffectView` (`.hudWindow`)
///   - 32pt content padding, large typography
///   - Step indicator dots at the bottom; ←/→ and Enter to navigate;
///     Esc dismisses (settings are applied on Done, NOT on Esc).
///
/// Recommended defaults applied when the user picks "Use recommended":
///   - theme            = TokyoNight Storm
///   - backgroundOpacity = 0.20
///   - blurLevel        = .light
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the user finishes or cancels. The caller usually opens
    /// the first terminal window after this fires.
    private let onFinish: () -> Void

    /// Live state — applied to `SettingsStore` only when the user reaches
    /// the final step. Esc dismissal bypasses persistence so a curious
    /// click doesn't permanently change anything.
    private var selectedTheme: String = "TokyoNight Storm"
    private var selectedOpacity: Double = 0.20
    private var selectedBlur: AppSettings.BlurLevel = .light

    private var currentStep: Int = 0
    private let stepCount = 4
    /// Guards `onFinish` against double-invocation. `finishAndClose` sets it
    /// before closing; `windowWillClose` checks it so the red-X close path
    /// (which bypasses `finishAndClose`) still spawns the first terminal
    /// window before AppKit asks `applicationShouldTerminate…`.
    private var didFireOnFinish = false

    private let contentArea = NSView()
    private let stepDots = NSStackView()
    private let backButton = NSButton()
    private let nextButton = NSButton()

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        // Behind-window blur — keeps the onboarding feeling like part of
        // the OS rather than a flat overlay.
        window.backgroundColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 0.85)
        window.isOpaque = false
        window.hasShadow = true

        super.init(window: window)
        window.delegate = self
        layoutChrome()
        renderCurrentStep()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Catch close paths that bypass `finishAndClose` — primarily the
        // red-X title-bar button. Without this, closing via the X leaves
        // no terminal window open and the app terminates instead of
        // landing the user on their first session.
        guard !didFireOnFinish else { return }
        didFireOnFinish = true
        markCompleteIfNeeded()
        onFinish()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Chrome layout

    private func layoutChrome() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(blur)

        contentArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentArea)

        stepDots.orientation = .horizontal
        stepDots.spacing = 8
        stepDots.alignment = .centerY
        stepDots.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<stepCount {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            stepDots.addArrangedSubview(dot)
        }
        content.addSubview(stepDots)

        Self.configureButton(backButton, title: "Back", primary: false)
        backButton.target = self
        backButton.action = #selector(handleBack(_:))
        backButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backButton)

        Self.configureButton(nextButton, title: "Get Started", primary: true)
        nextButton.target = self
        nextButton.action = #selector(handleNext(_:))
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(nextButton)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: content.topAnchor),
            blur.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            contentArea.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            contentArea.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 48),
            contentArea.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -48),
            contentArea.bottomAnchor.constraint(equalTo: stepDots.topAnchor, constant: -24),

            stepDots.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stepDots.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),

            backButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            backButton.centerYAnchor.constraint(equalTo: stepDots.centerYAnchor),

            nextButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            nextButton.centerYAnchor.constraint(equalTo: stepDots.centerYAnchor),
        ])
    }

    // MARK: - Step rendering

    private func renderCurrentStep() {
        contentArea.subviews.forEach { $0.removeFromSuperview() }
        let stepView: NSView
        switch currentStep {
        case 0: stepView = makeWelcomeStep()
        case 1: stepView = makeAppearanceStep()
        case 2: stepView = makeKeybindingsStep()
        default: stepView = makeDoneStep()
        }
        stepView.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(stepView)
        NSLayoutConstraint.activate([
            stepView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            stepView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            stepView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            stepView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])

        // Step-dot highlighting — current dot bright, the rest dim.
        for (i, dot) in stepDots.arrangedSubviews.enumerated() {
            let on = (i == currentStep)
            dot.layer?.backgroundColor = (on ? NSColor.white
                                              : NSColor.white.withAlphaComponent(0.25)).cgColor
        }

        backButton.isHidden = (currentStep == 0)
        nextButton.title = nextButtonTitle()

        // Crossfade between steps so it feels deliberate, not snappy.
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentArea.layer?.add(transition, forKey: kCATransition)
    }

    private func nextButtonTitle() -> String {
        switch currentStep {
        case 0: return "Get Started"
        case stepCount - 1: return "Start Using Gastty"
        default: return "Continue"
        }
    }

    // MARK: - Step 1: Welcome

    private func makeWelcomeStep() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 96, weight: .medium)
        icon.contentTintColor = NSColor(srgbRed: 0.65, green: 0.78, blue: 1.0, alpha: 1)
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(28, after: icon)

        let title = NSTextField(labelWithString: "Welcome to Gastty")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.alignment = .center
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "A fast, GPU-accelerated terminal for macOS. Let's get you set up — should take less than a minute.")
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 3
        stack.addArrangedSubview(subtitle)

        return Self.wrapCentered(stack)
    }

    // MARK: - Step 2: Appearance

    fileprivate struct ThemeOption {
        let name: String          // ghostty theme identifier
        let displayName: String   // shown in tile
        let background: NSColor   // approximate; for preview tile only
        let accent: NSColor       // small swatch on tile
        let recommended: Bool
    }

    fileprivate static let themeOptions: [ThemeOption] = [
        .init(name: "TokyoNight Storm", displayName: "TokyoNight Storm",
              background: NSColor(srgbRed: 0.141, green: 0.157, blue: 0.231, alpha: 1),
              accent:     NSColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1),
              recommended: true),
        .init(name: "Dracula", displayName: "Dracula",
              background: NSColor(srgbRed: 0.157, green: 0.165, blue: 0.212, alpha: 1),
              accent:     NSColor(srgbRed: 0.741, green: 0.576, blue: 0.976, alpha: 1),
              recommended: false),
        .init(name: "Nord", displayName: "Nord",
              background: NSColor(srgbRed: 0.180, green: 0.204, blue: 0.251, alpha: 1),
              accent:     NSColor(srgbRed: 0.533, green: 0.753, blue: 0.816, alpha: 1),
              recommended: false),
        .init(name: "Catppuccin Mocha", displayName: "Catppuccin Mocha",
              background: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.180, alpha: 1),
              accent:     NSColor(srgbRed: 0.796, green: 0.651, blue: 0.969, alpha: 1),
              recommended: false),
        .init(name: "Gruvbox Dark", displayName: "Gruvbox Dark",
              background: NSColor(srgbRed: 0.157, green: 0.157, blue: 0.157, alpha: 1),
              accent:     NSColor(srgbRed: 0.996, green: 0.502, blue: 0.098, alpha: 1),
              recommended: false),
        .init(name: "Atom One Dark", displayName: "Atom One Dark",
              background: NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1),
              accent:     NSColor(srgbRed: 0.380, green: 0.686, blue: 0.937, alpha: 1),
              recommended: false),
    ]

    private var themeTiles: [ThemeTileView] = []
    /// Status text shown next to the "Browse all themes…" link. Hidden
    /// when one of the 6 recommended tiles is the active selection;
    /// reveals "Custom: <name>" when the user picks a theme via the
    /// browser that isn't one of the tiles.
    private let customThemeLabel = NSTextField(labelWithString: "")

    private func makeAppearanceStep() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let title = NSTextField(labelWithString: "Choose your look")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString:
            "We've picked sensible defaults. Tweak now or later from Settings (⌘,).")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(20, after: subtitle)

        // Theme grid — 2 rows × 3 columns
        themeTiles = []
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        let cols = 3
        var row: [NSView] = []
        for option in Self.themeOptions {
            let tile = ThemeTileView(option: option,
                                     isSelected: option.name == selectedTheme) { [weak self] in
                self?.selectedTheme = option.name
                self?.themeTiles.forEach { $0.refreshSelection(selectedName: option.name) }
            }
            themeTiles.append(tile)
            row.append(tile)
            if row.count == cols {
                grid.addRow(with: row)
                row.removeAll()
            }
        }
        if !row.isEmpty { grid.addRow(with: row) }
        stack.addArrangedSubview(grid)
        stack.setCustomSpacing(10, after: grid)

        // "Browse all themes…" row — opens the full searchable picker as
        // a sheet over this window. Keeps the recommended tiles above as
        // the primary path; the link is for users who want to explore.
        let browseRow = makeBrowseRow()
        stack.addArrangedSubview(browseRow)
        stack.setCustomSpacing(20, after: browseRow)

        // Controls row: opacity + blur side by side
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .top
        controls.spacing = 24
        controls.distribution = .fillEqually

        controls.addArrangedSubview(makeOpacityControl())
        controls.addArrangedSubview(makeBlurControl())
        stack.addArrangedSubview(controls)

        return stack
    }

    private func makeBrowseRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let button = NSButton()
        button.title = "Browse all themes…"
        button.bezelStyle = .inline
        button.controlSize = .small
        button.target = self
        button.action = #selector(openThemeBrowser(_:))

        customThemeLabel.font = .systemFont(ofSize: 12)
        customThemeLabel.textColor = .tertiaryLabelColor
        customThemeLabel.lineBreakMode = .byTruncatingTail
        refreshCustomThemeLabel()

        row.addArrangedSubview(button)
        row.addArrangedSubview(customThemeLabel)
        return row
    }

    @objc private func openThemeBrowser(_ sender: Any?) {
        guard let parent = window else { return }
        ThemeBrowserController.present(over: parent, current: selectedTheme) { [weak self] picked in
            guard let self, let picked, !picked.isEmpty else { return }
            self.selectedTheme = picked
            self.themeTiles.forEach { $0.refreshSelection(selectedName: picked) }
            self.refreshCustomThemeLabel()
        }
    }

    /// Show "Custom: <name>" when the active selection isn't one of the
    /// six recommended tiles. When it is, the label is empty so the row
    /// stays clean.
    private func refreshCustomThemeLabel() {
        let isTile = Self.themeOptions.contains { $0.name == selectedTheme }
        if isTile {
            customThemeLabel.stringValue = ""
        } else {
            customThemeLabel.stringValue = "Selected: \(selectedTheme)"
        }
    }

    private func makeOpacityControl() -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6

        let label = NSTextField(labelWithString: "Background opacity")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: "\(Int(selectedOpacity * 100))%")
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.textColor = .tertiaryLabelColor

        let header = NSStackView(views: [label, NSView(), valueLabel])
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: selectedOpacity, minValue: 0.2, maxValue: 1.0,
                              target: nil, action: nil)
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(opacityChanged(_:))
        slider.identifier = NSUserInterfaceItemIdentifier("opacitySlider")
        slider.tag = 0
        slider.numberOfTickMarks = 9
        objc_setAssociatedObject(slider, &Self.opacityValueLabelKey, valueLabel, .OBJC_ASSOCIATION_ASSIGN)

        box.addArrangedSubview(header)
        box.addArrangedSubview(slider)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            slider.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    private static var opacityValueLabelKey: UInt8 = 0

    @objc private func opacityChanged(_ sender: NSSlider) {
        selectedOpacity = sender.doubleValue
        if let label = objc_getAssociatedObject(sender, &Self.opacityValueLabelKey) as? NSTextField {
            label.stringValue = "\(Int(selectedOpacity * 100))%"
        }
    }

    private func makeBlurControl() -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6

        let label = NSTextField(labelWithString: "Background blur")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor

        let segments = NSSegmentedControl(
            labels: ["Off", "Light", "Medium", "Strong"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(blurChanged(_:))
        )
        segments.segmentDistribution = .fillEqually
        segments.controlSize = .regular
        segments.selectedSegment = Self.blurSegmentIndex(for: selectedBlur)

        box.addArrangedSubview(label)
        box.addArrangedSubview(segments)

        NSLayoutConstraint.activate([
            segments.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            segments.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    @objc private func blurChanged(_ sender: NSSegmentedControl) {
        selectedBlur = Self.blurLevel(forSegment: sender.selectedSegment)
    }

    private static func blurSegmentIndex(for level: AppSettings.BlurLevel) -> Int {
        switch level {
        case .off:    return 0
        case .light:  return 1
        case .medium: return 2
        case .strong: return 3
        }
    }
    private static func blurLevel(forSegment idx: Int) -> AppSettings.BlurLevel {
        switch idx {
        case 1: return .light
        case 2: return .medium
        case 3: return .strong
        default: return .off
        }
    }

    // MARK: - Step 3: Keybindings

    private func makeKeybindingsStep() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let title = NSTextField(labelWithString: "Get to know the shortcuts")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString:
            "Worth memorising — they'll speed you up. Everything's also in the menus.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(20, after: subtitle)

        struct Binding { let keys: [String]; let title: String }
        let groups: [(String, [Binding])] = [
            ("Windows & tabs", [
                .init(keys: ["⌘", "N"], title: "New window"),
                .init(keys: ["⌘", "T"], title: "New tab"),
                .init(keys: ["⌘", "W"], title: "Close pane / tab"),
                .init(keys: ["⌘", "1–9"], title: "Switch to that tab"),
            ]),
            ("Splits & panes", [
                .init(keys: ["⌘", "D"], title: "Split right"),
                .init(keys: ["⌘", "⇧", "D"], title: "Split down"),
                .init(keys: ["⌘", "["], title: "Previous pane"),
                .init(keys: ["⌘", "]"], title: "Next pane"),
            ]),
            ("Connections & search", [
                .init(keys: ["⌘", "K"], title: "Quick Connect palette"),
                .init(keys: ["⌘", "S"], title: "Toggle saved-connections sidebar"),
                .init(keys: ["⌘", "F"], title: "Find in scrollback"),
                .init(keys: ["⌘", ","], title: "Open Settings"),
            ]),
        ]

        let columnStack = NSStackView()
        columnStack.orientation = .horizontal
        columnStack.alignment = .top
        columnStack.spacing = 28
        columnStack.distribution = .fillEqually

        for (groupTitle, items) in groups {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 8

            let header = NSTextField(labelWithString: groupTitle.uppercased())
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .tertiaryLabelColor
            col.addArrangedSubview(header)
            col.setCustomSpacing(6, after: header)

            for item in items {
                col.addArrangedSubview(makeBindingRow(keys: item.keys, title: item.title))
            }
            columnStack.addArrangedSubview(col)
        }
        stack.addArrangedSubview(columnStack)
        return stack
    }

    private func makeBindingRow(keys: [String], title: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4

        let keyStack = NSStackView()
        keyStack.orientation = .horizontal
        keyStack.spacing = 2
        for key in keys {
            keyStack.addArrangedSubview(makeKeyCap(key))
        }

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor

        row.addArrangedSubview(keyStack)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 10).isActive = true
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(label)
        return row
    }

    private func makeKeyCap(_ key: String) -> NSView {
        let cap = NSTextField(labelWithString: key)
        cap.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        cap.alignment = .center
        cap.textColor = NSColor.labelColor
        cap.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        cap.drawsBackground = true
        cap.isBordered = true
        cap.usesSingleLineMode = true
        cap.cell?.usesSingleLineMode = true
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 4
        cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        cap.layer?.borderWidth = 1
        cap.translatesAutoresizingMaskIntoConstraints = false

        let width: CGFloat = key.count == 1 ? 24 : (key.count <= 2 ? 28 : 40)
        NSLayoutConstraint.activate([
            cap.widthAnchor.constraint(equalToConstant: width),
            cap.heightAnchor.constraint(equalToConstant: 22),
        ])
        return cap
    }

    // MARK: - Step 4: Done

    private func makeDoneStep() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                             accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 96, weight: .medium)
        icon.contentTintColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 0.65, alpha: 1)
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(28, after: icon)

        let title = NSTextField(labelWithString: "You're all set")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.alignment = .center
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Press \"Start Using Gastty\" to open your first tab. Settings live under ⌘, and the Quick Connect palette is one keystroke away with ⌘K.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 4
        stack.addArrangedSubview(subtitle)

        return Self.wrapCentered(stack)
    }

    // MARK: - Navigation

    @objc private func handleNext(_ sender: Any?) {
        if currentStep == stepCount - 1 {
            commitAndFinish()
        } else {
            currentStep += 1
            renderCurrentStep()
        }
    }

    @objc private func handleBack(_ sender: Any?) {
        guard currentStep > 0 else { return }
        currentStep -= 1
        renderCurrentStep()
    }

    private func commitAndFinish() {
        SettingsStore.shared.update { s in
            s.theme = selectedTheme
            s.backgroundOpacity = selectedOpacity
            s.blurLevel = selectedBlur
            s.hasCompletedOnboarding = true
        }
        finishAndClose()
    }

    /// Mark complete even if the user dismisses without finishing — once
    /// they've seen the onboarding we don't want to keep nagging on every
    /// launch. They chose to skip; respect it.
    private func markCompleteIfNeeded() {
        if !SettingsStore.shared.settings.hasCompletedOnboarding {
            SettingsStore.shared.update { $0.hasCompletedOnboarding = true }
        }
    }

    private func finishAndClose() {
        // Order is load-bearing: open the terminal window FIRST, then close
        // ourselves. AppDelegate.applicationShouldTerminateAfterLastWindowClosed
        // returns true when no TerminalWindowController is visible, so if we
        // close the onboarding window before any terminal exists, AppKit
        // terminates the app before our callback can fire.
        guard !didFireOnFinish else { window?.close(); return }
        didFireOnFinish = true
        onFinish()
        window?.close()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            markCompleteIfNeeded()
            finishAndClose()
        case 36, 76: // Return / numpad enter
            handleNext(nil)
        case 123: // Left arrow
            handleBack(nil)
        case 124: // Right arrow
            handleNext(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Helpers

    private static func configureButton(_ button: NSButton, title: String, primary: Bool) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.keyEquivalent = primary ? "\r" : ""
        if primary {
            button.contentTintColor = .white
        }
    }

    private static func wrapCentered(_ inner: NSView) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            inner.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
            inner.topAnchor.constraint(greaterThanOrEqualTo: wrap.topAnchor),
            inner.bottomAnchor.constraint(lessThanOrEqualTo: wrap.bottomAnchor),
        ])
        return wrap
    }
}

// MARK: - Theme tile

private final class ThemeTileView: NSView {
    private let option: OnboardingWindowController.ThemeOption
    private let onPick: () -> Void
    private let card = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let recommendedBadge = NSTextField(labelWithString: "RECOMMENDED")
    private var hover = false

    init(option: OnboardingWindowController.ThemeOption,
         isSelected: Bool,
         onPick: @escaping () -> Void) {
        self.option = option
        self.onPick = onPick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 2
        addSubview(card)

        // Theme preview "screen" — the background swatch with a few stripes
        // hinting at fg + accent so each tile is visually distinct without
        // having to read the label.
        let bg = NSView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.backgroundColor = option.background.cgColor
        card.addSubview(bg)

        let fgBar = NSView()
        fgBar.translatesAutoresizingMaskIntoConstraints = false
        fgBar.wantsLayer = true
        fgBar.layer?.cornerRadius = 1
        fgBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        bg.addSubview(fgBar)

        let accentBar = NSView()
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = 1
        accentBar.layer?.backgroundColor = option.accent.cgColor
        bg.addSubview(accentBar)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = option.displayName
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.alignment = .center
        addSubview(nameLabel)

        recommendedBadge.translatesAutoresizingMaskIntoConstraints = false
        recommendedBadge.stringValue = "RECOMMENDED"
        recommendedBadge.font = .systemFont(ofSize: 8, weight: .bold)
        recommendedBadge.textColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 0.65, alpha: 1)
        recommendedBadge.alignment = .center
        recommendedBadge.isHidden = !option.recommended
        addSubview(recommendedBadge)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 180),

            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.heightAnchor.constraint(equalToConstant: 80),

            bg.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            bg.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            bg.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            bg.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),

            fgBar.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            fgBar.widthAnchor.constraint(equalToConstant: 60),
            fgBar.heightAnchor.constraint(equalToConstant: 2),
            fgBar.centerYAnchor.constraint(equalTo: bg.centerYAnchor, constant: -6),

            accentBar.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            accentBar.widthAnchor.constraint(equalToConstant: 36),
            accentBar.heightAnchor.constraint(equalToConstant: 2),
            accentBar.centerYAnchor.constraint(equalTo: bg.centerYAnchor, constant: 4),

            nameLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            recommendedBadge.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            recommendedBadge.leadingAnchor.constraint(equalTo: leadingAnchor),
            recommendedBadge.trailingAnchor.constraint(equalTo: trailingAnchor),
            recommendedBadge.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refreshSelection(selectedName: isSelected ? option.name : "")
        // Track hover for subtle highlight.
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refreshSelection(selectedName: String) {
        let selected = (selectedName == option.name)
        card.layer?.borderColor = selected
            ? NSColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(hover ? 0.20 : 0.08).cgColor
        card.layer?.borderWidth = selected ? 2 : 1
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        refreshSelection(selectedName: option.name == currentSelectedName ? option.name : "")
    }
    override func mouseExited(with event: NSEvent) {
        hover = false
        refreshSelection(selectedName: option.name == currentSelectedName ? option.name : "")
    }
    override func mouseDown(with event: NSEvent) {
        onPick()
    }

    /// Reflects what the controller currently considers selected — used so
    /// hover doesn't override the explicit selection visual.
    private var currentSelectedName: String {
        // No callback to read from the controller; safe to recompute from
        // border color. Border color is the source of truth between calls.
        if let border = card.layer?.borderColor,
           let parsed = NSColor(cgColor: border),
           parsed.redComponent > 0.4 && parsed.blueComponent > 0.8 {
            return option.name
        }
        return ""
    }
}
