import AppKit
import GhosttyKit

/// Minimal input forwarding to libghostty. ASCII typing and basic mouse work;
/// full IME support (CJK composition, dead keys) requires NSTextInputClient
/// — a follow-up task before international users are happy.
extension SurfaceHostView {

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        forwardKey(event: event, action: GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        forwardKey(event: event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        forwardKey(event: event, action: GHOSTTY_ACTION_PRESS)
    }

    /// Forward a single key event to libghostty.
    ///
    /// Pass the produced text via the `text` field of the key event struct,
    /// NOT via a separate `ghostty_surface_text` call — doing both inserts
    /// every character twice. Control characters (codepoint < 0x20) are
    /// encoded by libghostty itself, so leave `text = nil` for those —
    /// otherwise ctrl+Enter etc. produce the wrong byte sequence.
    private func forwardKey(event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = modsFrom(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = 0
        key.composing = false

        if let chars = event.characters,
           !chars.isEmpty,
           let first = chars.unicodeScalars.first,
           first.value >= 0x20 {
            chars.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    private func modsFrom(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)   { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)  { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock){ raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // MARK: - Mouse
    //
    // libghostty's mouse_pos takes LOGICAL POINTS in view-space with Y
    // measured from the TOP (so we flip AppKit's Y). It does NOT take
    // backing pixels — the size API takes pixels, but mouse is points.
    // This is the Ghostty SurfaceView_AppKit convention.

    override func mouseDown(with event: NSEvent) {
        // Update position BEFORE the button event — without tracking areas
        // libghostty's last-known mouse_pos would otherwise be stale, and
        // the start of a drag-selection would be miles from the click.
        forwardMousePos(event: event)
        forwardMouseButton(event: event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS)
    }
    override func mouseUp(with event: NSEvent) {
        forwardMousePos(event: event)
        forwardMouseButton(event: event, button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_RELEASE)
    }
    override func rightMouseDown(with event: NSEvent) {
        forwardMousePos(event: event)
        forwardMouseButton(event: event, button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_PRESS)
    }
    override func rightMouseUp(with event: NSEvent) {
        forwardMousePos(event: event)
        forwardMouseButton(event: event, button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func mouseMoved(with event: NSEvent)   { forwardMousePos(event: event) }
    override func mouseDragged(with event: NSEvent) { forwardMousePos(event: event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMousePos(event: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        var mods = ghostty_input_scroll_mods_t()
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        ghostty_surface_mouse_scroll(surface, Double(dx), Double(dy), mods)
    }

    private func forwardMouseButton(event: NSEvent,
                                    button: ghostty_input_mouse_button_e,
                                    state: ghostty_input_mouse_state_e) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, modsFrom(event.modifierFlags))
    }

    private func forwardMousePos(event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)   // logical points
        ghostty_surface_mouse_pos(surface,
                                  pos.x,
                                  frame.height - pos.y,        // flip Y to top-down
                                  modsFrom(event.modifierFlags))
    }
}
