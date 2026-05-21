import AppKit

/// Binary tree of terminal surfaces inside a single session (tab).
///
/// A leaf wraps one `SurfaceHostView`. A split wraps two children plus a
/// direction. Rendering produces an NSView tree where leaves are the real
/// surface views and inner nodes are `HalfSplitView`s (a custom split
/// view — see below).
final class SplitNode {
    enum Kind {
        case leaf(SurfaceHostView)
        /// `direction == .horizontal` means children sit side-by-side
        /// (vertical divider). `.vertical` means stacked top/bottom.
        case split(direction: NSUserInterfaceLayoutOrientation,
                   first: SplitNode,
                   second: SplitNode)
    }

    var kind: Kind
    weak var parent: SplitNode?

    /// Position of the divider as a fraction of the split's primary axis,
    /// in the range (0.0, 1.0). Only meaningful when `kind` is `.split`.
    /// Captured from the live `HalfSplitView` whenever the user drags, so
    /// switching tabs (which triggers a fresh `render()`) restores the
    /// user's chosen ratio instead of resetting to 50/50.
    var dividerRatio: Double = 0.5

    init(_ kind: Kind) {
        self.kind = kind
        link(children: kind)
    }

    private func link(children kind: Kind) {
        if case let .split(_, a, b) = kind {
            a.parent = self
            b.parent = self
        }
    }

    var isLeaf: Bool {
        if case .leaf = kind { return true }
        return false
    }

    var leafSurface: SurfaceHostView? {
        if case .leaf(let s) = kind { return s }
        return nil
    }

    /// All surfaces in the tree, in in-order traversal — used by ⌘[ / ⌘]
    /// previous/next navigation.
    func allLeaves() -> [SurfaceHostView] {
        switch kind {
        case .leaf(let s): return [s]
        case .split(_, let a, let b): return a.allLeaves() + b.allLeaves()
        }
    }

    /// Find the node whose .leaf is `surface`.
    func nodeContaining(_ surface: SurfaceHostView) -> SplitNode? {
        switch kind {
        case .leaf(let s):
            return s === surface ? self : nil
        case .split(_, let a, let b):
            return a.nodeContaining(surface) ?? b.nodeContaining(surface)
        }
    }

    func render() -> NSView {
        switch kind {
        case .leaf(let surface):
            surface.translatesAutoresizingMaskIntoConstraints = true
            return surface
        case .split(let direction, let a, let b):
            let split = HalfSplitView()
            split.isVertical = (direction == .horizontal)
            split.targetRatio = dividerRatio
            // Capture user drags back into the model so tab-switch /
            // session-restore preserve the position.
            split.onRatioChanged = { [weak self] ratio in
                self?.dividerRatio = ratio
            }
            split.setChildren(first: a.render(), second: b.render())
            return split
        }
    }

    // MARK: - Mutations

    /// Replace this leaf with a binary split. The current surface becomes one
    /// child; `newSurface` becomes the other. `placeNewAfter` controls
    /// whether the new surface sits to the right/below (true) or
    /// left/above (false) of the existing one.
    func splitLeaf(direction: NSUserInterfaceLayoutOrientation,
                   newSurface: SurfaceHostView,
                   placeNewAfter: Bool) {
        guard case .leaf(let existing) = kind else { return }
        let existingNode = SplitNode(.leaf(existing))
        let newNode = SplitNode(.leaf(newSurface))
        let first  = placeNewAfter ? existingNode : newNode
        let second = placeNewAfter ? newNode : existingNode
        let newKind: Kind = .split(direction: direction, first: first, second: second)
        first.parent = self
        second.parent = self
        kind = newKind
    }

    /// Collapse a leaf out of the tree. Returns the new root of the tree
    /// (the caller swaps it in if it's different from `self`).
    static func remove(_ leaf: SurfaceHostView, from root: SplitNode) -> SplitNode? {
        guard let node = root.nodeContaining(leaf) else { return root }
        // node is a leaf.
        guard let parent = node.parent else {
            // root was a single leaf — closing it means the session is empty.
            return nil
        }
        // The sibling replaces the parent in the grandparent (or becomes root).
        guard case let .split(_, a, b) = parent.kind else { return root }
        let sibling = (a === node) ? b : a
        if let grand = parent.parent {
            guard case let .split(dir, ga, gb) = grand.kind else { return root }
            let newFirst  = (ga === parent) ? sibling : ga
            let newSecond = (gb === parent) ? sibling : gb
            sibling.parent = grand
            grand.kind = .split(direction: dir, first: newFirst, second: newSecond)
            return root
        } else {
            // Parent IS the root. Sibling becomes the new root.
            sibling.parent = nil
            return sibling
        }
    }
}

// MARK: - HalfSplitView (custom)

/// Hand-rolled two-pane split view. Replaces the previous NSSplitView
/// subclass to get rid of NSSplitView's quirks: thin un-grabbable
/// dividers, weird default subview distribution, the deferred initial
/// balance gymnastics we needed for nested splits, and the indirect
/// drag-detection via notification + `NSApp.currentEvent` polling.
///
/// What this gives you:
///
///   - **Thicker hit area** (8pt) wrapped around a 1pt visible line.
///     Easy to grab without needing pixel-perfect aim. Visible
///     thickness stays minimal so the chrome isn't loud.
///   - **Hover feedback**: the line brightens and thickens slightly
///     when the mouse is over the divider.
///   - **Double-click to equalise**: snaps back to 50/50 with a short
///     animation.
///   - **Proportional resize**: when the parent (window/parent split)
///     resizes, the divider keeps its ratio rather than its absolute
///     position. Layout recomputes from `targetRatio` × axis every
///     pass, so this is automatic.
///   - **Min pane size** (80pt) enforced by clamping the ratio in
///     both layout and drag. Below 2×80+gap the clamp relaxes so
///     extremely narrow windows still render.
///
/// API is matched to what `SplitNode.render()` needs:
///   - `isVertical: Bool` — `true` means the divider is a vertical
///     line and children sit side-by-side (= horizontal split). Matches
///     NSSplitView's naming.
///   - `targetRatio: Double` — first pane's size as a fraction of the
///     primary axis (in (0, 1)). 0.5 by default; restored from
///     `SplitNode.dividerRatio` on render.
///   - `onRatioChanged: ((Double) -> Void)?` — fires on every drag
///     update so the model captures the live position; SplitNode
///     writes back to `dividerRatio`.
///   - `setChildren(first:second:)` — install the two children.
final class HalfSplitView: NSView {

    // MARK: - Public configuration

    /// `true` = divider is a vertical line, children laid out horizontally
    /// (side-by-side). `false` = horizontal divider, children stacked
    /// (first on top, second on bottom).
    var isVertical: Bool = true {
        didSet {
            if oldValue != isVertical {
                divider.needsDisplay = true
                needsLayout = true
            }
        }
    }

    /// First pane's size as a fraction of the primary axis. Clamped at
    /// layout time so neither pane drops below `minPaneSize`.
    var targetRatio: Double = 0.5 {
        didSet {
            if oldValue != targetRatio {
                needsLayout = true
            }
        }
    }

    /// Fires every time a user drag changes the ratio. The owning
    /// `SplitNode` uses this to persist the position back to the model.
    var onRatioChanged: ((Double) -> Void)?

    // MARK: - Tunables

    /// Floor for both panes' size on the divider's axis. ~5–6 cells at
    /// the default font — small enough that the user can still squash a
    /// pane down hard, big enough that a stray drag can't make a pane
    /// unusable.
    private let minPaneSize: CGFloat = 80

    /// How wide the divider's mouse-event hit area is. Generous so it's
    /// easy to grab.
    private let dividerHitThickness: CGFloat = 8

    // MARK: - State

    private var firstChild: NSView?
    private var secondChild: NSView?
    private let divider = DividerView()

    private var dragStartRatio: Double = 0.5
    private var dragStartMouseInSplit: NSPoint = .zero

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        divider.splitView = self
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Children

    /// Install or replace the two child views. The divider stays on
    /// top in the subview order so its hit area can extend a few
    /// points into each child's territory without losing clicks.
    func setChildren(first: NSView, second: NSView) {
        firstChild?.removeFromSuperview()
        secondChild?.removeFromSuperview()
        addSubview(first, positioned: .below, relativeTo: divider)
        addSubview(second, positioned: .below, relativeTo: divider)
        first.translatesAutoresizingMaskIntoConstraints = true
        second.translatesAutoresizingMaskIntoConstraints = true
        firstChild = first
        secondChild = second
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutChildren()
    }

    private func layoutChildren() {
        guard let first = firstChild, let second = secondChild else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 0 else { return }

        let clamped = clampedRatio(targetRatio, total: total)
        let dividerPos = total * CGFloat(clamped)
        let halfHit = dividerHitThickness / 2

        if isVertical {
            // Side-by-side: first on the left, second on the right, divider
            // is a vertical strip centred on dividerPos.
            first.frame = NSRect(x: 0, y: 0,
                                  width: dividerPos,
                                  height: bounds.height)
            second.frame = NSRect(x: dividerPos, y: 0,
                                   width: bounds.width - dividerPos,
                                   height: bounds.height)
            divider.frame = NSRect(x: dividerPos - halfHit, y: 0,
                                    width: dividerHitThickness,
                                    height: bounds.height)
        } else {
            // Stacked: first on top (high y in non-flipped coords), second
            // on bottom (y=0), divider strip centred on the boundary.
            let firstHeight = bounds.height * CGFloat(clamped)
            first.frame = NSRect(x: 0,
                                  y: bounds.height - firstHeight,
                                  width: bounds.width,
                                  height: firstHeight)
            second.frame = NSRect(x: 0, y: 0,
                                   width: bounds.width,
                                   height: bounds.height - firstHeight)
            divider.frame = NSRect(x: 0,
                                    y: bounds.height - firstHeight - halfHit,
                                    width: bounds.width,
                                    height: dividerHitThickness)
        }
    }

    /// Clamp `ratio` so neither pane drops below `minPaneSize`. When the
    /// split is too narrow for both minimums to hold simultaneously the
    /// clamp relaxes to (0, 1) so the view still renders.
    private func clampedRatio(_ ratio: Double, total: CGFloat) -> Double {
        guard total > 0 else { return ratio }
        if total < minPaneSize * 2 + 1 {
            return max(0.0, min(1.0, ratio))
        }
        let minR = Double(minPaneSize) / Double(total)
        let maxR = 1 - minR
        return max(minR, min(maxR, ratio))
    }

    // MARK: - Drag (called by DividerView)

    fileprivate func beginDividerDrag(at locationInWindow: NSPoint) {
        dragStartRatio = targetRatio
        dragStartMouseInSplit = convert(locationInWindow, from: nil)
    }

    fileprivate func updateDividerDrag(at locationInWindow: NSPoint) {
        let total = isVertical ? bounds.width : bounds.height
        guard total > 0 else { return }
        let mouseInSplit = convert(locationInWindow, from: nil)

        // Compute delta along the divider's movement axis. For the
        // stacked layout we invert the y delta because AppKit's
        // non-flipped y grows upward but the first pane is on TOP — so
        // mouse-up means the divider goes up and the first pane shrinks.
        let delta: CGFloat
        if isVertical {
            delta = mouseInSplit.x - dragStartMouseInSplit.x
        } else {
            delta = -(mouseInSplit.y - dragStartMouseInSplit.y)
        }

        let proposed = dragStartRatio + Double(delta) / Double(total)
        let newRatio = clampedRatio(proposed, total: total)
        guard abs(newRatio - targetRatio) > 0.001 else { return }
        targetRatio = newRatio
        onRatioChanged?(newRatio)
    }

    fileprivate func endDividerDrag() {
        // No-op: we ship updates on every `updateDividerDrag` call.
    }

    /// Double-click handler — equalise the split with a short animation.
    fileprivate func equalizeRatio() {
        let target: Double = 0.5
        guard let first = firstChild, let second = secondChild else {
            targetRatio = target
            onRatioChanged?(target)
            return
        }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 0 else {
            targetRatio = target
            onRatioChanged?(target)
            return
        }
        let clamped = clampedRatio(target, total: total)
        let dividerPos = total * CGFloat(clamped)
        let halfHit = dividerHitThickness / 2

        // Build the destination frames using the same math as
        // `layoutChildren`, then animate frames into them. We update
        // `targetRatio` synchronously so any layout pass triggered
        // during the animation reads the new value.
        targetRatio = clamped

        let firstTarget: NSRect
        let secondTarget: NSRect
        let dividerTarget: NSRect
        if isVertical {
            firstTarget = NSRect(x: 0, y: 0,
                                  width: dividerPos, height: bounds.height)
            secondTarget = NSRect(x: dividerPos, y: 0,
                                   width: bounds.width - dividerPos,
                                   height: bounds.height)
            dividerTarget = NSRect(x: dividerPos - halfHit, y: 0,
                                    width: dividerHitThickness,
                                    height: bounds.height)
        } else {
            let firstHeight = bounds.height * CGFloat(clamped)
            firstTarget = NSRect(x: 0, y: bounds.height - firstHeight,
                                  width: bounds.width, height: firstHeight)
            secondTarget = NSRect(x: 0, y: 0,
                                   width: bounds.width,
                                   height: bounds.height - firstHeight)
            dividerTarget = NSRect(x: 0,
                                    y: bounds.height - firstHeight - halfHit,
                                    width: bounds.width,
                                    height: dividerHitThickness)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            first.animator().frame = firstTarget
            second.animator().frame = secondTarget
            divider.animator().frame = dividerTarget
        }, completionHandler: nil)

        onRatioChanged?(clamped)
    }
}

// MARK: - DividerView

/// The strip that lives between the two panes. The view itself is
/// `dividerHitThickness` wide along the divider's axis (8pt by default)
/// so it's easy to grab; the visible line is drawn 1pt thick in the
/// centre. The owning `HalfSplitView` handles all positioning and the
/// actual ratio math — this view only tracks mouse interaction.
private final class DividerView: NSView {

    weak var splitView: HalfSplitView?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let opts: NSTrackingArea.Options = [
            .activeInActiveApp,
            .mouseEnteredAndExited,
            .cursorUpdate,
            .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts,
                                   owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let sv = splitView else {
            super.cursorUpdate(with: event)
            return
        }
        if sv.isVertical {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.resizeUpDown.set()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        // Don't drop the hover state while a drag is still in flight —
        // the cursor will travel outside the original bounds.
        if !isDragging { isHovered = false }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            splitView?.equalizeRatio()
            return
        }
        isDragging = true
        isHovered = true
        splitView?.beginDividerDrag(at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        splitView?.updateDividerDrag(at: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        splitView?.endDividerDrag()
        // Re-evaluate hover state — the cursor may have wandered out of
        // our bounds during the drag.
        let mouseInSelf = convert(event.locationInWindow, from: nil)
        isHovered = bounds.contains(mouseInSelf)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let sv = splitView else { return }
        let lineColor: NSColor
        let lineWidth: CGFloat
        if isHovered || isDragging {
            lineColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
            lineWidth = 2
        } else {
            lineColor = NSColor.separatorColor.withAlphaComponent(0.5)
            lineWidth = 1
        }
        lineColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        if sv.isVertical {
            let x = bounds.midX
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
        } else {
            let y = bounds.midY
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
        }
        path.stroke()
    }
}
