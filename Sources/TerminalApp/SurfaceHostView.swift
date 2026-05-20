import AppKit
import GhosttyKit
import QuartzCore

/// An NSView that hosts a single `ghostty_surface_t`.
///
/// libghostty drives the Metal renderer directly into this view's layer.
/// The view forwards input events (keyboard, mouse, IME) to the surface
/// via the libghostty C API.
final class SurfaceHostView: NSView {

    let runtime: GhosttyRuntime
    var surface: ghostty_surface_t?

    /// Back-reference to the owning session. Set by `Session` on creation.
    /// Used by the action callback to find which session contains the
    /// surface that fired a split / goto-split action.
    weak var session: Session?

    /// Optional command to spawn instead of `$SHELL`. Used to start an SSH
    /// session directly from a Quick Connect entry. Read on surface creation.
    let initialCommand: String?

    /// Optional working directory the new shell should start in. Set when
    /// restoring a session so a fresh shell lands in the same folder as
    /// the one that was running before the relaunch.
    let initialWorkingDirectory: String?

    /// The shell's most recently reported working directory (via OSC 7 /
    /// libghostty's PWD action). Captured so we can persist it on quit.
    var workingDirectory: String?

    init(runtime: GhosttyRuntime, command: String? = nil, workingDirectory: String? = nil) {
        self.runtime = runtime
        self.initialCommand = command
        self.initialWorkingDirectory = workingDirectory
        self.workingDirectory = workingDirectory
        // Start with a non-zero frame so the CAMetalLayer's bounds are sane
        // before the first render pass. Ghostty's own SurfaceView does the
        // same — without it, the renderer initializes degenerate and stays
        // off-by-a-cell after layout catches up.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.wantsLayer = true
        self.layer = CAMetalLayer()
        if let metal = self.layer as? CAMetalLayer {
            metal.isOpaque = false
            metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        }
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        runtime.unregister(surface: self)
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, surface == nil, let app = runtime.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window.backingScaleFactor)
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()

        // Two optional C strings (command + working_directory) need to stay
        // valid for the duration of `ghostty_surface_new`. Nested
        // `withCString` keeps both pointers alive together.
        let cmd = initialCommand
        let wd = initialWorkingDirectory
        switch (cmd, wd) {
        case (let cmd?, let wd?):
            cmd.withCString { cmdPtr in
                wd.withCString { wdPtr in
                    cfg.command = cmdPtr
                    cfg.working_directory = wdPtr
                    self.surface = withUnsafePointer(to: &cfg) { ghostty_surface_new(app, $0) }
                }
            }
        case (let cmd?, nil):
            cmd.withCString { cmdPtr in
                cfg.command = cmdPtr
                self.surface = withUnsafePointer(to: &cfg) { ghostty_surface_new(app, $0) }
            }
        case (nil, let wd?):
            wd.withCString { wdPtr in
                cfg.working_directory = wdPtr
                self.surface = withUnsafePointer(to: &cfg) { ghostty_surface_new(app, $0) }
            }
        case (nil, nil):
            self.surface = withUnsafePointer(to: &cfg) { ghostty_surface_new(app, $0) }
        }
        guard let surface else { return }

        runtime.register(surface: self)
        applyScaleAndSize()
        ghostty_surface_set_focus(surface, true)
    }

    /// Apply the current window backing scale and view size to the surface.
    /// Order matters: content scale must be set BEFORE size, otherwise
    /// libghostty computes the cell grid against the previous scale and the
    /// cursor ends up one cell out of step with the text.
    private func applyScaleAndSize() {
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor

        // Prevent Core Animation from re-scaling the drawable itself; we
        // want the Metal renderer to drive every pixel.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let metal = self.layer as? CAMetalLayer {
            metal.contentsScale = scale
            let backing = convertToBacking(bounds.size)
            metal.drawableSize = CGSize(width: max(1, backing.width),
                                        height: max(1, backing.height))
        }
        CATransaction.commit()

        let fb = convertToBacking(frame)
        let xScale = frame.size.width > 0 ? fb.size.width / frame.size.width : scale
        let yScale = frame.size.height > 0 ? fb.size.height / frame.size.height : scale
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        let pxSize = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface,
                                 UInt32(max(1, pxSize.width)),
                                 UInt32(max(1, pxSize.height)))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        // When the user clicks on a different pane, update the session's
        // active surface so subsequent ⌘D / ⌘W / ⌘[ target this pane.
        session?.activeSurface = self
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScaleAndSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScaleAndSize()
    }

    // MARK: - Responder-chain actions
    //
    // These are invoked by the standard macOS menu items (Edit > Copy / Paste,
    // View > Zoom In / Out / Reset) via the responder chain. SurfaceHostView
    // is first responder in the window, so AppKit walks here first.
    //
    // libghostty exposes copy/paste and font sizing as named "binding
    // actions", invoked by `ghostty_surface_binding_action`. This is exactly
    // how a user's keybinding (e.g. `ctrl+shift+c=copy_to_clipboard`) would
    // fire — we just trigger the same path from menus.

    private func perform(action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
    }

    @objc func copy(_ sender: Any?) { perform(action: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform(action: "paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { perform(action: "select_all") }

    @objc func zoomIn(_ sender: Any?) { perform(action: "increase_font_size:1") }
    @objc func zoomOut(_ sender: Any?) { perform(action: "decrease_font_size:1") }
    @objc func zoomReset(_ sender: Any?) { perform(action: "reset_font_size") }
}

extension SurfaceHostView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)),
             #selector(paste(_:)),
             #selector(selectAll(_:)),
             #selector(zoomIn(_:)),
             #selector(zoomOut(_:)),
             #selector(zoomReset(_:)):
            return surface != nil
        default:
            return true
        }
    }
}
