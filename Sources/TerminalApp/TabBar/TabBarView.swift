import AppKit

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didActivate session: Session)
    func tabBar(_ bar: TabBarView, didRequestCloseOf session: Session)
    func tabBar(_ bar: TabBarView, didRequestDuplicateOf session: Session)
    func tabBarRequestsNewTab(_ bar: TabBarView)
}

/// Horizontal tab strip across the top of the surface area. Tabs live
/// inside a horizontal `NSScrollView` so excess tabs scroll inside a
/// fixed viewport instead of forcing the window to grow. When the
/// stack overflows the visible area, chevron-left / chevron-right
/// buttons appear between the strip and the "+" button.
///
/// Layout, left to right:
///
///   [ scroll-view containing tab stack ] [◀] [▶] [+] [workspace switcher]
///
/// The arrow buttons are hidden when there's no overflow (`isHidden`,
/// so they take no space). Within the scroll view, the stack's
/// `widthAnchor >= contentView.widthAnchor` so under-flowing tab counts
/// still expand to fill the visible bar (with fillEqually distribution),
/// matching the pre-scroll behaviour.
///
/// Other features unchanged: rename (double-click), drag-reorder, per-tab
/// close button, right-click context menu.
final class TabBarView: NSView {

    weak var delegate: TabBarDelegate?

    private(set) var sessions: [Session] = []
    private(set) var activeSession: Session?

    private var items: [UUID: TabItemView] = [:]
    /// Width/height constraints we install per item, tracked so drag can
    /// deactivate them cleanly when lifting the item out of the stack.
    private var itemSizeConstraints: [UUID: [NSLayoutConstraint]] = [:]
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let scrollLeftButton = NSButton()
    private let scrollRightButton = NSButton()
    private let newTabButton = NSButton()
    let workspaceSwitcher = WorkspaceSwitcherView()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Transparent so the title bar (above, also transparent) and the
        // tab bar read as one continuous strip. The terminal surface starts
        // below the 1px chrome separator owned by TerminalWindowController.
        layer?.backgroundColor = NSColor.clear.cgColor

        // Stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .centerY
        stack.spacing = 2

        // Scroll view wrapping the stack — horizontal-only, no visible
        // scrollers (the arrow buttons replace them), no background fill.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = stack
        addSubview(scrollView)

        // Stack pins to the clip view on three sides only — leading + top
        // + bottom. Width is left unconstrained against the clip view so
        // the stack uses its own intrinsic size (sum of each tab's
        // preferred width). With fewer tabs than would overflow, the
        // stack ends up narrower than the clip view, which is fine: the
        // bar shows the tabs flush left and the empty space is on the
        // right (just before the scroll arrows / + / workspace pill).
        // No tab stretching to "fill" the bar.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        ])

        configureChromeButton(scrollLeftButton, symbol: "chevron.left",
                              action: #selector(scrollLeftTapped(_:)),
                              accessibilityLabel: "Scroll tabs left")
        configureChromeButton(scrollRightButton, symbol: "chevron.right",
                              action: #selector(scrollRightTapped(_:)),
                              accessibilityLabel: "Scroll tabs right")
        configureChromeButton(newTabButton, symbol: "plus",
                              action: #selector(newTab(_:)),
                              accessibilityLabel: "New tab")
        // Arrows are hidden by default — `updateScrollArrows` flips them
        // on whenever overflow is detected.
        scrollLeftButton.isHidden = true
        scrollRightButton.isHidden = true

        addSubview(scrollLeftButton)
        addSubview(scrollRightButton)
        addSubview(newTabButton)

        workspaceSwitcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(workspaceSwitcher)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scrollView.trailingAnchor.constraint(equalTo: scrollLeftButton.leadingAnchor, constant: -6),

            scrollLeftButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollLeftButton.trailingAnchor.constraint(equalTo: scrollRightButton.leadingAnchor, constant: -2),
            scrollLeftButton.widthAnchor.constraint(equalToConstant: 22),
            scrollLeftButton.heightAnchor.constraint(equalToConstant: 22),

            scrollRightButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollRightButton.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -6),
            scrollRightButton.widthAnchor.constraint(equalToConstant: 22),
            scrollRightButton.heightAnchor.constraint(equalToConstant: 22),

            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: workspaceSwitcher.leadingAnchor, constant: -8),
            newTabButton.widthAnchor.constraint(equalToConstant: 22),
            newTabButton.heightAnchor.constraint(equalToConstant: 22),

            workspaceSwitcher.centerYAnchor.constraint(equalTo: centerYAnchor),
            workspaceSwitcher.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        // Observe scroll position changes to keep arrow enabled/disabled
        // state accurate (left arrow greys out at the leftmost scroll
        // position; right arrow at the rightmost).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        // Re-evaluate overflow after any layout pass — tab additions/
        // removals and window resizes both end up here.
        updateScrollArrows()
    }

    private func configureChromeButton(_ button: NSButton,
                                       symbol: String,
                                       action: Selector,
                                       accessibilityLabel: String) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func newTab(_ sender: Any?) {
        delegate?.tabBarRequestsNewTab(self)
    }

    // MARK: - Scrolling

    @objc private func scrollLeftTapped(_ sender: Any?) {
        scrollHorizontally(by: -180)
    }

    @objc private func scrollRightTapped(_ sender: Any?) {
        scrollHorizontally(by: 180)
    }

    private func scrollHorizontally(by delta: CGFloat) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x += delta
        let maxX = max(0, stack.bounds.width - clip.bounds.width)
        origin.x = max(0, min(maxX, origin.x))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrollDidChange(_ note: Notification) {
        updateScrollArrows()
    }

    /// Show / hide the chevron buttons based on whether the stack
    /// overflows the visible area, and toggle their enabled state based
    /// on whether there's actually room to scroll in that direction.
    private func updateScrollArrows() {
        let clip = scrollView.contentView
        let stackWidth = stack.bounds.width
        let visibleWidth = clip.bounds.width
        let overflow = stackWidth > visibleWidth + 1  // +1 dodges float noise

        scrollLeftButton.isHidden = !overflow
        scrollRightButton.isHidden = !overflow

        let offsetX = clip.bounds.origin.x
        scrollLeftButton.isEnabled = offsetX > 0
        scrollRightButton.isEnabled = offsetX < stackWidth - visibleWidth - 1
    }

    /// Scroll the visible area so the active tab is in view. Called
    /// whenever the active session changes so the user can always see
    /// which tab they're on. Deferred to next runloop so the layout
    /// pass that placed the new tab has finished before we query its
    /// frame.
    private func scrollActiveTabIntoView() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let active = self.activeSession,
                  let item = self.items[active.id] else { return }
            let clip = self.scrollView.contentView
            let visible = clip.bounds
            let itemFrame = item.frame  // in stack coordinates
            if itemFrame.maxX > visible.maxX {
                let newX = itemFrame.maxX - visible.width + 8
                clip.scroll(to: NSPoint(x: newX, y: visible.origin.y))
                self.scrollView.reflectScrolledClipView(clip)
            } else if itemFrame.minX < visible.minX {
                let newX = max(0, itemFrame.minX - 8)
                clip.scroll(to: NSPoint(x: newX, y: visible.origin.y))
                self.scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    /// Preferred width per tab. Browser-style — tabs are a consistent
    /// size rather than stretching to fill the bar when there's only
    /// a handful of them.
    private static let tabPreferredWidth: CGFloat = 200

    private func applySizeConstraints(to item: TabItemView) {
        item.translatesAutoresizingMaskIntoConstraints = false
        let sessionID = item.session.id
        if let previous = itemSizeConstraints[sessionID] {
            NSLayoutConstraint.deactivate(previous)
        }
        let preferredWidth = item.widthAnchor.constraint(equalToConstant: Self.tabPreferredWidth)
        // `.defaultHigh` (750) so the preferred width holds in normal
        // layouts but can bend when the runtime layout system has
        // overriding requirements. The required min-width still
        // protects against squishing below the readable threshold.
        preferredWidth.priority = .defaultHigh

        let fresh: [NSLayoutConstraint] = [
            item.heightAnchor.constraint(equalToConstant: 22),
            item.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            preferredWidth,
        ]
        item.setContentHuggingPriority(.required, for: .vertical)
        item.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate(fresh)
        itemSizeConstraints[sessionID] = fresh
    }

    // MARK: - Sessions

    func add(session: Session, activate: Bool = true) {
        sessions.append(session)
        let item = TabItemView(session: session, tabBar: self)
        items[session.id] = item
        stack.addArrangedSubview(item)
        applySizeConstraints(to: item)
        if activate { setActive(session: session) }
        updateVisibility()
        scrollActiveTabIntoView()
    }

    func remove(session: Session) {
        guard let item = items[session.id] else { return }
        if let constraints = itemSizeConstraints.removeValue(forKey: session.id) {
            NSLayoutConstraint.deactivate(constraints)
        }
        stack.removeArrangedSubview(item)
        item.removeFromSuperview()
        items.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        if activeSession?.id == session.id {
            activeSession = sessions.last
            if let next = activeSession {
                items[next.id]?.isActive = true
                delegate?.tabBar(self, didActivate: next)
            }
        }
        updateVisibility()
        scrollActiveTabIntoView()
    }

    func setActive(session: Session) {
        activeSession = session
        for (id, item) in items {
            item.isActive = (id == session.id)
        }
        delegate?.tabBar(self, didActivate: session)
        scrollActiveTabIntoView()
    }

    func activateNext() { advance(by: +1) }
    func activatePrevious() { advance(by: -1) }
    func activate(index: Int) {
        guard sessions.indices.contains(index) else { return }
        setActive(session: sessions[index])
    }
    var count: Int { sessions.count }
    var isEmpty: Bool { sessions.isEmpty }

    private func advance(by delta: Int) {
        guard !sessions.isEmpty, let current = activeSession,
              let idx = sessions.firstIndex(where: { $0.id == current.id }) else { return }
        let next = (idx + delta + sessions.count) % sessions.count
        setActive(session: sessions[next])
    }

    func refreshTitles() { items.values.forEach { $0.refreshTitle() } }

    func move(session: Session, to index: Int) {
        guard let currentIndex = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let clamped = max(0, min(sessions.count - 1, index))
        if currentIndex == clamped { return }
        let s = sessions.remove(at: currentIndex)
        sessions.insert(s, at: clamped)
        if let view = items[session.id] {
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: clamped)
        }
    }

    /// Convert a mouse location (already in this view's coordinate space) to
    /// the index the dragged tab should snap to. The stack lives inside a
    /// scroll view but `stack.convert(_:to:)` accounts for the clip view's
    /// scroll offset, so this still works whether or not the bar is scrolled.
    func dropIndex(forLocal point: NSPoint) -> Int {
        for (idx, v) in stack.arrangedSubviews.enumerated() {
            let center = stack.convert(NSPoint(x: v.frame.midX, y: 0), to: self).x
            if point.x < center { return idx }
        }
        return sessions.count - 1
    }

    // MARK: - Lifted drag (called by TabItemView during mouseDown loop)

    private final class DragSession {
        let item: TabItemView
        let placeholder: NSView
        let mouseStartInBar: NSPoint
        let itemFrameAtStart: NSRect

        init(item: TabItemView, placeholder: NSView,
             mouseStartInBar: NSPoint, itemFrameAtStart: NSRect) {
            self.item = item
            self.placeholder = placeholder
            self.mouseStartInBar = mouseStartInBar
            self.itemFrameAtStart = itemFrameAtStart
        }
    }
    private var dragSession: DragSession?
    private var placeholderSizeConstraints: [NSLayoutConstraint] = []
    /// Drives auto-scroll when the user drags a tab into the left/right
    /// edge zone of the scroll view. Direction is -1 / 0 / +1.
    private var autoScrollDirection: CGFloat = 0
    private var autoScrollTimer: Timer?
    /// Mouse position from the most recent `updateDrag` call, kept so
    /// the auto-scroll timer can re-run drag positioning each tick with
    /// the current cursor location (the user might be holding still in
    /// the edge zone while the strip keeps scrolling underneath them).
    private var lastDragMouseInWindow: NSPoint = .zero

    /// Lift the tab out of the stack and re-parent it as an absolute child of
    /// this bar so it can follow the cursor. A placeholder takes its slot in
    /// the stack so siblings don't collapse. The lifted tab is added to
    /// `self` (the tab bar) so it floats above the scroll view rather than
    /// being clipped by it.
    func beginDrag(_ item: TabItemView, mouseLocationInWindow: NSPoint) {
        guard let stackIndex = stack.arrangedSubviews.firstIndex(of: item) else { return }
        let originalSize = item.bounds.size
        let frameInBar = item.convert(item.bounds, to: self)
        let mouseInBar = convert(mouseLocationInWindow, from: nil)

        if let prior = itemSizeConstraints.removeValue(forKey: item.session.id) {
            NSLayoutConstraint.deactivate(prior)
        }

        let placeholder = NSView()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        let phConstraints: [NSLayoutConstraint] = [
            placeholder.heightAnchor.constraint(equalToConstant: originalSize.height),
            placeholder.widthAnchor.constraint(greaterThanOrEqualToConstant: max(120, originalSize.width)),
        ]
        NSLayoutConstraint.activate(phConstraints)
        placeholderSizeConstraints = phConstraints

        stack.removeArrangedSubview(item)
        item.removeFromSuperview()
        stack.insertArrangedSubview(placeholder, at: stackIndex)

        item.translatesAutoresizingMaskIntoConstraints = true
        item.autoresizingMask = []
        addSubview(item, positioned: .above, relativeTo: scrollView)
        item.frame = frameInBar
        item.wantsLayer = true
        item.layer?.shadowOpacity = 0.4
        item.layer?.shadowOffset = CGSize(width: 0, height: 2)
        item.layer?.shadowRadius = 8
        item.layer?.shadowColor = NSColor.black.cgColor
        item.layer?.zPosition = 10

        dragSession = DragSession(
            item: item,
            placeholder: placeholder,
            mouseStartInBar: mouseInBar,
            itemFrameAtStart: frameInBar
        )
    }

    func updateDrag(mouseLocationInWindow: NSPoint) {
        guard let drag = dragSession else { return }
        lastDragMouseInWindow = mouseLocationInWindow
        let inBar = convert(mouseLocationInWindow, from: nil)
        let dx = inBar.x - drag.mouseStartInBar.x

        var newFrame = drag.itemFrameAtStart
        newFrame.origin.x += dx
        // Clamp the lifted tab to the scroll view's horizontal bounds so it
        // can't slide on top of the trailing chrome (scroll arrows / + /
        // workspace switcher).
        let leftBound = scrollView.frame.minX
        let rightBound = scrollView.frame.maxX - newFrame.width
        newFrame.origin.x = max(leftBound, min(rightBound, newFrame.origin.x))
        drag.item.frame = newFrame

        let targetIndex = dropIndex(forLocal: inBar)
        if let currentIndex = stack.arrangedSubviews.firstIndex(of: drag.placeholder),
           currentIndex != targetIndex {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                stack.removeArrangedSubview(drag.placeholder)
                stack.insertArrangedSubview(drag.placeholder, at: targetIndex)
            }
        }

        // Auto-scroll when the drag enters the leading/trailing edge zone
        // of the scroll view. The scroll keeps going on a timer for as
        // long as the cursor stays in the zone, so the user can hold
        // still and the strip pages itself.
        let edgeZone: CGFloat = 40
        if inBar.x < scrollView.frame.minX + edgeZone {
            setAutoScroll(direction: -1)
        } else if inBar.x > scrollView.frame.maxX - edgeZone {
            setAutoScroll(direction: +1)
        } else {
            setAutoScroll(direction: 0)
        }
    }

    /// Set the auto-scroll direction (-1 = left, 0 = stopped, +1 = right)
    /// and start / stop the driving timer accordingly. Idempotent — the
    /// timer keeps running with the latest direction, and stops cleanly
    /// when direction goes back to 0 or the drag ends.
    ///
    /// The timer is added to `.common` mode explicitly. The drag itself
    /// runs inside `window.nextEvent(matching:)` which puts the runloop
    /// in event-tracking mode; `Timer.scheduledTimer` only fires in
    /// default mode, so without `.common` the auto-scroll would never
    /// tick mid-drag.
    private func setAutoScroll(direction: CGFloat) {
        autoScrollDirection = direction
        if direction == 0 {
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
            return
        }
        if autoScrollTimer != nil { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
        RunLoop.current.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func autoScrollTick() {
        guard dragSession != nil, autoScrollDirection != 0 else {
            setAutoScroll(direction: 0)
            return
        }
        // Step size per frame — about 8pt at 60Hz feels close to a tab
        // width per second. Adjust if it feels too fast or sluggish.
        scrollHorizontally(by: autoScrollDirection * 8)
        // Re-run the drag positioning with the current cursor location
        // so the placeholder slot tracks the newly-visible tabs while
        // the user holds still.
        updateDrag(mouseLocationInWindow: lastDragMouseInWindow)
    }

    func endDrag() {
        guard let drag = dragSession else { return }
        dragSession = nil
        setAutoScroll(direction: 0)
        let targetFrame = drag.placeholder.convert(drag.placeholder.bounds, to: self)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drag.item.animator().frame = targetFrame
        }, completionHandler: { [weak self, weak placeholder = drag.placeholder] in
            guard let self, let placeholder,
                  let stackIndex = self.stack.arrangedSubviews.firstIndex(of: placeholder) else {
                drag.item.removeFromSuperview()
                return
            }

            NSLayoutConstraint.deactivate(self.placeholderSizeConstraints)
            self.placeholderSizeConstraints.removeAll()
            self.stack.removeArrangedSubview(placeholder)
            placeholder.removeFromSuperview()

            drag.item.removeFromSuperview()
            drag.item.layer?.shadowOpacity = 0
            drag.item.layer?.zPosition = 0
            drag.item.translatesAutoresizingMaskIntoConstraints = false
            self.stack.insertArrangedSubview(drag.item, at: stackIndex)
            self.applySizeConstraints(to: drag.item)

            if let logicalIndex = self.sessions.firstIndex(where: { $0.id == drag.item.session.id }),
               logicalIndex != stackIndex {
                let s = self.sessions.remove(at: logicalIndex)
                self.sessions.insert(s, at: stackIndex)
            }
        })
    }

    /// Keep the bar visible whenever there's at least one tab so the user
    /// can rename or close it.
    private func updateVisibility() {
        isHidden = sessions.isEmpty
        invalidateIntrinsicContentSize()
    }

    // MARK: - Called by TabItemView

    func activate(session: Session) { setActive(session: session) }
    func close(session: Session) { delegate?.tabBar(self, didRequestCloseOf: session) }
    func duplicate(session: Session) { delegate?.tabBar(self, didRequestDuplicateOf: session) }
}
