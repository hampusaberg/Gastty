import AppKit

/// Binary tree of terminal surfaces inside a single session (tab).
///
/// A leaf wraps one `SurfaceHostView`. A split wraps two children plus a
/// direction. Rendering produces an NSView tree where leaves are the real
/// surface views and inner nodes are `NSSplitView`s.
///
/// Note: this is the simple "plain NSSplitView" version. We attempted
/// caching the split view and tracking divider ratios in earlier rounds,
/// but those layers caused structural bugs when nesting splits. The plain
/// version reliably lets you split a pane any number of times, like Ghostty.
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
            split.dividerStyle = .thin
            split.isVertical = (direction == .horizontal)
            split.addArrangedSubview(a.render())
            split.addArrangedSubview(b.render())
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

/// NSSplitView subclass that forces a 50/50 split on its first non-zero
/// layout pass. Without this, NSSplitView's default behavior gives the
/// first added subview its existing frame width and the second only the
/// leftover, which cascades through nested splits into the
/// "wide-left, tiny-right" layout the user saw. After the initial balance
/// the flag locks so user-dragged dividers aren't overridden.
final class HalfSplitView: NSSplitView {
    private var hasBalanced = false
    override func layout() {
        super.layout()
        guard !hasBalanced, arrangedSubviews.count == 2 else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 0 else { return }
        // CRITICAL: set the flag BEFORE `setPosition`. NSSplitView's
        // `setPosition` synchronously triggers another `layout()`; if the
        // flag is still false at that point we'd infinitely recurse and
        // crash the app on the first split.
        hasBalanced = true
        setPosition(total / 2, ofDividerAt: 0)
    }
}
