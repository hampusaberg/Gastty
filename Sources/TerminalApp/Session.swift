import AppKit

/// A tab in a window. Owns a tree of surfaces (one leaf per pane).
final class Session {
    let id = UUID()

    /// Root of the split tree. Single-pane sessions have a leaf root.
    var rootNode: SplitNode

    /// The pane currently focused inside this session.
    var activeSurface: SurfaceHostView

    /// Display title shown in the tab.
    var title: String

    /// Set to true after the user double-clicks-renames a tab. Future
    /// OSC-title escapes from the shell will be ignored when this is true.
    var titleLocked: Bool = false

    /// Pending OSC title update scheduled for application after the debounce
    /// window. Cancelled if a newer title arrives before it fires.
    private var pendingTitleUpdate: DispatchWorkItem?

    /// Schedule an OSC-driven title update. Multiple updates arriving in
    /// rapid succession (typical from zsh themes that set both `user@host`
    /// and cwd on every prompt) collapse into the final one.
    func scheduleTitleUpdate(to newTitle: String,
                             controller: TerminalWindowController) {
        pendingTitleUpdate?.cancel()
        let item = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller else { return }
            if self.titleLocked { return }
            self.title = newTitle
            controller.refreshSessionTitle(self)
        }
        pendingTitleUpdate = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80),
                                      execute: item)
    }

    init(runtime: GhosttyRuntime, title: String = "Gastty", command: String? = nil) {
        let surface = SurfaceHostView(runtime: runtime, command: command)
        self.rootNode = SplitNode(.leaf(surface))
        self.activeSurface = surface
        self.title = title
        surface.session = self
    }

    /// Restore a session from persisted state. Rebuilds the split tree with
    /// new SurfaceHostViews — each new shell will land in the saved
    /// working directory if there was one.
    init(runtime: GhosttyRuntime, restoring state: PersistedSessionState) {
        let (root, firstLeaf) = Session.buildTree(state.root, runtime: runtime)
        self.rootNode = root
        self.activeSurface = firstLeaf
        self.title = state.title
        self.titleLocked = state.titleLocked
        for leaf in root.allLeaves() {
            leaf.session = self
        }
    }

    private static func buildTree(_ persisted: PersistedSplitNode,
                                  runtime: GhosttyRuntime)
        -> (SplitNode, SurfaceHostView) {
        switch persisted {
        case .leaf(let cwd):
            let surface = SurfaceHostView(runtime: runtime, workingDirectory: cwd)
            return (SplitNode(.leaf(surface)), surface)
        case .split(let orientation, let first, let second):
            let (firstNode, firstLeaf) = buildTree(first, runtime: runtime)
            let (secondNode, _) = buildTree(second, runtime: runtime)
            let direction: NSUserInterfaceLayoutOrientation =
                orientation == .horizontal ? .horizontal : .vertical
            let node = SplitNode(.split(direction: direction,
                                        first: firstNode,
                                        second: secondNode))
            return (node, firstLeaf)
        }
    }

    /// Encode this session for persistence.
    func toPersisted() -> PersistedSessionState {
        PersistedSessionState(
            title: title,
            titleLocked: titleLocked,
            root: Session.persistedTree(rootNode)
        )
    }

    private static func persistedTree(_ node: SplitNode) -> PersistedSplitNode {
        switch node.kind {
        case .leaf(let surface):
            // Prefer the live cwd reported by the shell; fall back to
            // whatever we were originally spawned with.
            let cwd = surface.workingDirectory ?? surface.initialWorkingDirectory
            return .leaf(workingDirectory: cwd)
        case .split(let direction, let first, let second):
            let orientation: PersistedOrientation =
                direction == .horizontal ? .horizontal : .vertical
            return .split(orientation: orientation,
                          first: persistedTree(first),
                          second: persistedTree(second))
        }
    }

    /// Compatibility shim. The window controller used to hold a single
    /// `surfaceView`; now it asks the session for the active pane's view.
    var surfaceView: SurfaceHostView { activeSurface }

    /// Recursively rebuild the NSView hierarchy for this session.
    func renderTreeView() -> NSView { rootNode.render() }

    // MARK: - Split / close

    func split(activeFrom: SurfaceHostView,
               direction: NSUserInterfaceLayoutOrientation,
               placeNewAfter: Bool,
               runtime: GhosttyRuntime) -> SurfaceHostView? {
        guard let node = rootNode.nodeContaining(activeFrom) else { return nil }
        let newSurface = SurfaceHostView(runtime: runtime)
        newSurface.session = self
        node.splitLeaf(direction: direction,
                       newSurface: newSurface,
                       placeNewAfter: placeNewAfter)
        activeSurface = newSurface
        return newSurface
    }

    /// Returns true if the session is now empty (caller should close the tab).
    func remove(surface: SurfaceHostView) -> Bool {
        if let newRoot = SplitNode.remove(surface, from: rootNode) {
            rootNode = newRoot
            // Pick a new active surface: prefer first remaining leaf.
            if !rootNode.allLeaves().contains(where: { $0 === activeSurface }) {
                activeSurface = rootNode.allLeaves().first ?? activeSurface
            }
            return false
        } else {
            return true
        }
    }

    /// ⌘[ / ⌘] — cycle focus among leaves in document order.
    func focusAdjacentLeaf(forward: Bool) -> SurfaceHostView? {
        let leaves = rootNode.allLeaves()
        guard leaves.count > 1, let idx = leaves.firstIndex(where: { $0 === activeSurface }) else {
            return nil
        }
        let next = forward
            ? (idx + 1) % leaves.count
            : (idx - 1 + leaves.count) % leaves.count
        activeSurface = leaves[next]
        return activeSurface
    }

    enum FocusDirection { case left, right, up, down }

    /// ⌥⌘+arrow — focus the closest pane in the given direction.
    /// Spatial search across all leaves: picks the leaf whose center lies in
    /// the requested half-plane relative to the active leaf and is closest.
    func focusLeaf(in direction: FocusDirection) -> SurfaceHostView? {
        let leaves = rootNode.allLeaves()
        guard leaves.count > 1, activeSurface.window != nil else { return nil }
        let activeCenter = centerInWindow(activeSurface)

        var best: (leaf: SurfaceHostView, distance: CGFloat)?
        for leaf in leaves where leaf !== activeSurface {
            guard leaf.window === activeSurface.window else { continue }
            let center = centerInWindow(leaf)
            let dx = center.x - activeCenter.x
            // AppKit non-flipped: y grows upward. "Up" means higher y.
            let dy = center.y - activeCenter.y
            let isDirectional: Bool
            switch direction {
            case .left:  isDirectional = dx < -1
            case .right: isDirectional = dx > 1
            case .up:    isDirectional = dy > 1
            case .down:  isDirectional = dy < -1
            }
            if !isDirectional { continue }
            // Penalize off-axis distance so a pane directly in the
            // requested direction beats a corner-neighbor.
            let primary  = direction == .left || direction == .right ? abs(dx) : abs(dy)
            let secondary = direction == .left || direction == .right ? abs(dy) : abs(dx)
            let weighted = primary + secondary * 2
            if best == nil || weighted < best!.distance {
                best = (leaf, weighted)
            }
        }
        if let next = best?.leaf {
            activeSurface = next
            return next
        }
        return nil
    }

    private func centerInWindow(_ host: SurfaceHostView) -> NSPoint {
        let bounds = host.convert(host.bounds, to: nil)
        return NSPoint(x: bounds.midX, y: bounds.midY)
    }
}
