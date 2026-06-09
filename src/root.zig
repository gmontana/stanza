//! Stanza — a small line editor for terminal programs.
//!
//! ```zig
//! var ed = stanza.Editor.init(allocator, .{});
//! defer ed.deinit();
//! ed.history.load(".myapp_history") catch {};
//! while (true) {
//!     const line = ed.prompt("app ❯ ") catch |err| switch (err) {
//!         error.Eof => break,        // Ctrl-D on an empty line
//!         error.Interrupted => continue, // Ctrl-C
//!         else => return err,
//!     };
//!     defer allocator.free(line);
//!     try ed.history.add(line);
//!     // ... use line ...
//! }
//! ed.history.save(".myapp_history") catch {};
//! ```
//!
//! Completion, hints, and highlighting are opt-in via the `Config` callbacks.
//! On a non-terminal stdin/stdout the editor degrades to a plain line read.

const std = @import("std");

pub const Editor = @import("editor.zig").Editor;
pub const Step = Editor.Step;
pub const History = @import("history.zig").History;
pub const Key = @import("key.zig").Key;

const config = @import("config.zig");
pub const Config = config.Config;
pub const Editing = config.Editing;
pub const Color = config.Color;
pub const Style = config.Style;
pub const Hint = config.Hint;
pub const Completions = config.Completions;
pub const Candidate = config.Candidate;
pub const Painter = config.Painter;
pub const CompleteFn = config.CompleteFn;
pub const CompleteStyle = config.CompleteStyle;
pub const HintFn = config.HintFn;
pub const PaintFn = config.PaintFn;

test {
    std.testing.refAllDecls(@This());
}
