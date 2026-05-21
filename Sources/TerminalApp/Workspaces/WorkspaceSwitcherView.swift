import AppKit

/// Compact pill button shown at the trailing edge of the tab bar.
/// Displays the active workspace's SF Symbol + name (truncated) + a
/// down-chevron. Click pops up an `NSMenu` listing all workspaces
/// (current one checked) plus a "+ New Workspace…" item that opens
/// the editor sheet.
final class WorkspaceSwitcherView: NSButton {

    /// Owning window, used to anchor the New Workspace sheet.
    weak var ownerWindow: NSWindow?

    init() {
        super.init(frame: .zero)
        bezelStyle = .recessed
        isBordered = true
        controlSize = .small
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 11, weight: .medium)
        target = self
        action = #selector(showMenu(_:))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: WorkspaceStore.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: WorkspaceStore.didSwitch,
            object: nil
        )

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refresh() {
        let active = WorkspaceStore.shared.active
        // Truncate names visually — keeping the button compact in the
        // tab bar matters more than showing the full name. The menu
        // shows the full name on click anyway.
        let display = Self.truncate(active.name, max: 12)
        title = "  \(display)  ⌄"
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        image = NSImage(systemSymbolName: active.iconSymbol,
                        accessibilityDescription: active.name)?
            .withSymbolConfiguration(cfg)
        toolTip = "Workspace: \(active.name)"
        invalidateIntrinsicContentSize()
    }

    @objc private func showMenu(_ sender: Any?) {
        let menu = NSMenu()
        let store = WorkspaceStore.shared
        for ws in store.workspaces {
            let item = NSMenuItem(title: ws.name,
                                  action: #selector(pickWorkspace(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = ws.id
            item.image = NSImage(systemSymbolName: ws.iconSymbol,
                                 accessibilityDescription: ws.name)
            if ws.id == store.activeID {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let newItem = NSMenuItem(title: "New Workspace…",
                                 action: #selector(newWorkspace(_:)),
                                 keyEquivalent: "")
        newItem.target = self
        newItem.image = NSImage(systemSymbolName: "plus",
                                accessibilityDescription: "New workspace")
        menu.addItem(newItem)

        // Only offer rename / delete when the active isn't the
        // protected Default workspace (which is always first in the list).
        if store.workspaces.first?.id != store.activeID {
            let renameItem = NSMenuItem(title: "Rename Current Workspace…",
                                        action: #selector(renameActive(_:)),
                                        keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)

            let deleteItem = NSMenuItem(title: "Delete Current Workspace",
                                        action: #selector(deleteActive(_:)),
                                        keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
        }

        // Show the menu anchored to the button so it appears beneath it.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: bounds.height),
                   in: self)
    }

    @objc private func pickWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        WorkspaceStore.shared.switchTo(id)
    }

    @objc private func newWorkspace(_ sender: Any?) {
        guard let parent = ownerWindow else { return }
        WorkspaceEditor.presentNew(over: parent) { name, icon in
            let ws = WorkspaceStore.shared.add(name: name, iconSymbol: icon)
            WorkspaceStore.shared.switchTo(ws.id)
        }
    }

    @objc private func renameActive(_ sender: Any?) {
        guard let parent = ownerWindow else { return }
        let current = WorkspaceStore.shared.active
        WorkspaceEditor.presentEdit(over: parent, existing: current) { name, icon in
            WorkspaceStore.shared.rename(current.id, to: name)
            WorkspaceStore.shared.setIcon(current.id, symbol: icon)
        }
    }

    @objc private func deleteActive(_ sender: Any?) {
        let current = WorkspaceStore.shared.active
        guard let parent = ownerWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(current.name)?"
        alert.informativeText = "Its saved connections and open tabs for this workspace will be removed. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent) { response in
            guard response == .alertFirstButtonReturn else { return }
            WorkspaceStore.shared.remove(current.id)
        }
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
