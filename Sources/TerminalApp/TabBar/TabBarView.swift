import AppKit

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didActivate session: Session)
    func tabBar(_ bar: TabBarView, didRequestCloseOf session: Session)
    func tabBar(_ bar: TabBarView, didRequestDuplicateOf session: Session)
    func tabBarRequestsNewTab(_ bar: TabBarView)
}

/// Horizontal tab strip across the top of the surface area. Supports
/// rename (double-click), drag-reorder, per-tab close button, plus button,
/// and right-click context menu.
final class TabBarView: NSView {

    weak var delegate: TabBarDelegate?

    private(set) var sessions: [Session] = []
    private(set) var activeSession: Session?

    private var items: [UUID: TabItemView] = [:]
    /// Width/height constraints we install per item, tracked so drag can
    /// deactivate them cleanly when lifting the item out of the stack.
    private var itemSizeConstraints: [UUID: [NSLayoutConstraint]] = [:]
    private let stack = NSStackView()
    private let newTabButton = NSButton()

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

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .centerY
        stack.spacing = 2
        addSubview(stack)

        newTabButton.bezelStyle = .regularSquare
        newTabButton.isBordered = false
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        newTabButton.imagePosition = .imageOnly
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTabButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -6),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            newTabButton.widthAnchor.constraint(equalToConstant: 22),
            newTabButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func newTab(_ sender: Any?) {
        delegate?.tabBarRequestsNewTab(self)
    }

    private func applySizeConstraints(to item: TabItemView) {
        item.translatesAutoresizingMaskIntoConstraints = false
        let sessionID = item.session.id
        if let previous = itemSizeConstraints[sessionID] {
            NSLayoutConstraint.deactivate(previous)
        }
        let fresh: [NSLayoutConstraint] = [
            item.heightAnchor.constraint(equalToConstant: 22),
            item.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
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
    }

    func setActive(session: Session) {
        activeSession = session
        for (id, item) in items {
            item.isActive = (id == session.id)
        }
        delegate?.tabBar(self, didActivate: session)
    }

    func activateNext()     { advance(by: +1) }
    func activatePrevious() { advance(by: -1) }
    func activate(index: Int) {
        guard sessions.indices.contains(index) else { return }
        setActive(session: sessions[index])
    }
    var count: Int { sessions.count }

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
    /// the index the dragged tab should snap to.
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

    /// Lift the tab out of the stack and re-parent it as an absolute child of
    /// this bar so it can follow the cursor. A placeholder takes its slot in
    /// the stack so siblings don't collapse.
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
        addSubview(item, positioned: .above, relativeTo: stack)
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
        let inBar = convert(mouseLocationInWindow, from: nil)
        let dx = inBar.x - drag.mouseStartInBar.x

        var newFrame = drag.itemFrameAtStart
        newFrame.origin.x += dx
        newFrame.origin.x = max(8, min(bounds.maxX - newFrame.width - 32, newFrame.origin.x))
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
    }

    func endDrag() {
        guard let drag = dragSession else { return }
        dragSession = nil
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
    func close(session: Session)    { delegate?.tabBar(self, didRequestCloseOf: session) }
    func duplicate(session: Session){ delegate?.tabBar(self, didRequestDuplicateOf: session) }
}
