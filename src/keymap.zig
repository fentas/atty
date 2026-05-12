//! Keymap — proxy-level key bindings, dwm `keys[]` style.
//!
//! The terminal sends one or more bytes per keypress (`\x1b[C` for
//! right-arrow, `\x06` for Ctrl-F, …). When the proxy reads stdin and
//! the bytes match a `Binding.bytes`, the corresponding `Action` runs
//! instead of the original keystroke being forwarded to the shell.
//!
//! atty defines the closed set of `Action`s; user configs assemble
//! the bindings list. Modifier keys are baked into the byte sequence
//! itself — `\x1b[1;5C` is Ctrl-Right, etc. — so there's no separate
//! modifier field to bookkeep.
//!
//! Why this lives at the proxy and not on a module: the trigger ("this
//! key was pressed") and the payload ("the ghost text from whichever
//! module won the gather race") are decoupled. A single accept key
//! shouldn't have to know whether atuin or history provided the
//! suggestion.

pub const Action = enum {
    /// Replace the keystroke with the bytes of the currently-visible
    /// ghost suggestion (i.e. accept fish-style autosuggestion).
    /// No-op when no ghost is showing or the line is in an uncertain
    /// state.
    ghost_accept,
};

pub const Binding = struct {
    /// The raw bytes the terminal emits for the key. Matched against
    /// the entire stdin read — terminals send most named keys as a
    /// single read, but the match is byte-exact so chunked reads (rare)
    /// won't trigger.
    bytes: []const u8,
    action: Action,
};
