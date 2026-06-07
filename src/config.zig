//! Public configuration: colors and styles, the hint/completion/highlight
//! callback types, and the builder objects those callbacks fill.
//!
//! Callbacks are plain function pointers carrying an opaque `ctx` so Stanza
//! never reaches for `anytype`; the host casts `ctx` back to its own type.

const std = @import("std");

/// SGR foreground colors. Values are the ANSI codes themselves.
pub const Color = enum(u8) {
    default = 39,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    gray = 90,
};

/// A text style applied by the highlighter or shown behind a hint.
pub const Style = struct {
    color: Color = .default,
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,
};

/// Ghost text shown after the cursor when it sits at the end of the line.
/// Callback text is trusted application output and should be valid UTF-8.
pub const Hint = struct {
    text: []const u8,
    style: Style = .{ .color = .gray },
};

/// Collects completion candidates. Backed by an arena the editor owns and
/// resets between requests, so callbacks never worry about freeing.
pub const Completions = struct {
    items: std.ArrayList([]const u8) = .empty,
    arena: std.mem.Allocator,

    /// Add one candidate; the text is copied into the arena as provided.
    /// Candidate text is trusted application output and should be valid UTF-8.
    pub fn add(self: *Completions, text: []const u8) !void {
        try self.items.append(self.arena, try self.arena.dupe(u8, text));
    }
};

/// Receives the styled rendering of the line from a highlighter. Visible
/// characters must match the input; only zero-width SGR escapes may be added.
pub const Painter = struct {
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    /// Append trusted UTF-8 text with no styling.
    pub fn plain(self: *Painter, text: []const u8) !void {
        try self.buf.appendSlice(self.alloc, text);
    }

    /// Append trusted UTF-8 text wrapped in the given style, then reset.
    pub fn put(self: *Painter, text: []const u8, style: Style) !void {
        try self.openSgr(style);
        try self.buf.appendSlice(self.alloc, text);
        try self.buf.appendSlice(self.alloc, "\x1b[0m");
    }

    fn openSgr(self: *Painter, style: Style) !void {
        try self.buf.appendSlice(self.alloc, "\x1b[");
        if (style.bold) try self.buf.appendSlice(self.alloc, "1;");
        if (style.dim) try self.buf.appendSlice(self.alloc, "2;");
        if (style.underline) try self.buf.appendSlice(self.alloc, "4;");
        var num: [3]u8 = undefined;
        const code = std.fmt.bufPrint(&num, "{d}", .{@intFromEnum(style.color)}) catch "39";
        try self.buf.appendSlice(self.alloc, code);
        try self.buf.appendSlice(self.alloc, "m");
    }
};

/// Called on Tab with the full line, byte cursor, and current word. Add
/// full-word replacements to `out`.
pub const CompleteFn = *const fn (
    ctx: ?*anyopaque,
    line: []const u8,
    cursor: usize,
    word: []const u8,
    out: *Completions,
) anyerror!void;

/// Called after each edit with the whole line; return ghost text or null.
pub const HintFn = *const fn (ctx: ?*anyopaque, line: []const u8) ?Hint;

/// Called to render the line; write the styled form to `out`.
pub const PaintFn = *const fn (ctx: ?*anyopaque, line: []const u8, out: *Painter) anyerror!void;

/// Key-binding style. `emacs` is the modeless readline default; `vi` adds a
/// modal normal/insert split (starting in insert).
pub const Editing = enum { emacs, vi };

/// What Tab does with several completion candidates: `.list` prints them,
/// `.cycle` walks them inline, and `.menu` keeps a small selector visible
/// below the prompt.
pub const CompleteStyle = enum { list, cycle, menu };

/// Behavior of an `Editor`. All fields are optional; the zero value is a plain
/// editor with history but no completion, hints, or highlighting.
pub const Config = struct {
    /// Opaque pointer handed back to every callback.
    ctx: ?*anyopaque = null,
    /// Key-binding style; defaults to vi (starts in insert mode).
    editing: Editing = .vi,
    complete: ?CompleteFn = null,
    complete_style: CompleteStyle = .list,
    hint: ?HintFn = null,
    paint: ?PaintFn = null,
    /// Wrap long lines across rows instead of scrolling a single row. Note:
    /// highlighting and hints apply only in the default single-line mode.
    multiline: bool = false,
    /// When set, render this codepoint in place of every character (passwords).
    mask: ?u21 = null,
    /// Cap on completion candidates printed by a Tab listing; the remainder
    /// is summarized as "… (N more)" so huge candidate sets cannot flood the
    /// screen.
    max_listed: usize = 100,
    /// If true on POSIX, `editStart` installs a process-wide SIGWINCH handler
    /// so the editor can reflow on resize. Leave false when the host owns
    /// signals; on Windows, call `Editor.notifyResize` after observing a resize.
    install_resize_handler: bool = false,
    /// Maximum retained history entries.
    max_history: usize = 1000,
};

test "completion candidates are copied as trusted bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var comps = Completions{ .arena = arena.allocator() };

    try comps.add("ok\xff");

    try std.testing.expectEqual(@as(usize, 1), comps.items.items.len);
    try std.testing.expectEqualStrings("ok\xff", comps.items.items[0]);
}
