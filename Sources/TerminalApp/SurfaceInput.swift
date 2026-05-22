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

    /// Forward a single key event to libghostty, following the same
    /// pattern as upstream Ghostty's `SurfaceView_AppKit` — see
    /// `NSEvent.ghosttyKeyEvent` and `NSEvent.ghosttyText` below for
    /// the per-field convention. Highlights:
    ///
    ///   - `unshifted_codepoint` is derived from
    ///     `characters(byApplyingModifiers: [])` so libghostty has a
    ///     layout-stable identity for binding matching.
    ///   - `consumed_mods` is everything except Ctrl/Cmd — Ghostty's
    ///     long-standing heuristic for which modifiers AppKit
    ///     consumed when producing `characters`.
    ///   - `text` strips Ctrl before asking AppKit to translate, so
    ///     for Ctrl+C we pass "c" + the Ctrl mod and let libghostty's
    ///     `KeyEncoder` emit either the legacy 0x03 byte or the
    ///     kitty-protocol `ESC[99;5u` sequence depending on what the
    ///     TUI (Claude Code, vim, etc.) has negotiated.
    ///
    /// Without this convention, Ctrl+letter inside any TUI that opts
    /// into the kitty keyboard protocol silently no-ops because
    /// libghostty receives only the keycode and modifiers — no letter
    /// to encode.
    private func forwardKey(event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = event.ghosttyKeyEvent(action)

        // Pick the text per Ghostty's `ghosttyText` convention. Then
        // the same belt-and-suspenders check Ghostty does: even if a
        // control byte leaks through, refuse to send it as text —
        // libghostty encodes those itself.
        let text = event.ghosttyText
        if let text, !text.isEmpty,
           let first = text.utf8.first, first >= 0x20 {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
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

    override func mouseMoved(with event: NSEvent) { forwardMousePos(event: event) }
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
        _ = ghostty_surface_mouse_button(surface, state, button, ghosttyModsFrom(event.modifierFlags))
    }

    private func forwardMousePos(event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)   // logical points
        ghostty_surface_mouse_pos(surface,
                                  pos.x,
                                  frame.height - pos.y,        // flip Y to top-down
                                  ghosttyModsFrom(event.modifierFlags))
    }
}

// MARK: - NSEvent → libghostty
//
// These two helpers mirror upstream Ghostty's
// `NSEvent+Extension.swift` (`ghosttyKeyEvent` + `ghosttyCharacters`).
// Keeping the same surface area means we stay in sync if libghostty's
// expectations shift — and means a future port of the upstream IME /
// kitty-protocol plumbing (NSTextInputClient, performKeyEquivalent,
// command-mod replay) drops in cleanly on top.

private extension NSEvent {

    /// Build a populated `ghostty_input_key_s` for this NSEvent. Does
    /// NOT set `text` or `composing` — the caller fills those in.
    ///
    /// `consumed_mods` follows Ghostty's heuristic: Ctrl and Cmd never
    /// contribute to AppKit's text translation; everything else
    /// (Shift, Option, Caps) does.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.composing = false
        key.mods = ghosttyModsFrom(modifierFlags)
        key.consumed_mods = ghosttyModsFrom(
            (translationMods ?? modifierFlags).subtracting([.control, .command])
        )

        // Layout-stable identity for binding matches.
        key.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// Text to forward as the `text` field. Mirrors Ghostty's
    /// `ghosttyCharacters`:
    ///
    ///   - **Control characters** (codepoint < 0x20): AppKit pre-encoded
    ///     them (Ctrl+C → "\u{03}"). Return the letter *without* Ctrl
    ///     applied so libghostty's KeyEncoder can synthesize either
    ///     the legacy byte or the kitty-protocol CSI sequence
    ///     depending on what the TUI requested.
    ///   - **PUA function keys** (0xF700–0xF8FF): arrows, F1–F35,
    ///     Home/End, etc. Return nil so libghostty's keycode-driven
    ///     path takes over.
    ///   - **Everything else**: pass through verbatim.
    var ghosttyText: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(
                    byApplyingModifiers: modifierFlags.subtracting(.control)
                )
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}

/// Module-level mods helper so both `SurfaceHostView.forwardKey` and
/// the `NSEvent` extension above can call into it without re-declaring.
private func ghosttyModsFrom(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
}
