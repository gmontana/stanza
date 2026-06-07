//! Completion engine: candidate gathering, list/cycle/menu behavior, and the
//! small amount of terminal drawing needed for a live completion menu.

const std = @import("std");
const config = @import("config.zig");
const key = @import("key.zig");
const render = @import("render.zig");
const sys = @import("sys.zig");
const unicode = @import("unicode.zig");
const Line = @import("line.zig").Line;

pub const CycleState = struct {
    items: []const []const u8,
    shown_len: usize,
    idx: usize,
};

pub const MenuState = struct {
    items: []const []const u8,
    saved: []const u8,
    shown_len: usize,
    idx: usize,
};

pub const Engine = struct {
    alloc: std.mem.Allocator,
    cfg: config.Config,
    term: *sys.Terminal,
    line: *Line,
    arena: *std.heap.ArenaAllocator,
    out: *std.ArrayList(u8),
    ml_row: *usize,
    cycle: *?CycleState,
    menu: *?MenuState,
    hidden: bool,
};

pub const MenuResult = enum { handled, pass };
const Dir = enum { fwd, back };

/// Menu rows are deliberately few: the menu redraws every keystroke, and a
/// tall menu at the bottom of the screen would scroll the scrollback away.
const max_menu_rows: usize = 8;

pub fn complete(e: *Engine) !void {
    switch (e.cfg.complete_style) {
        .list => try completeList(e),
        .cycle => try cycleStep(e, .fwd),
        .menu => if (e.cfg.multiline) try cycleStep(e, .fwd) else try menuBegin(e, .fwd),
    }
}

pub fn back(e: *Engine) !void {
    switch (e.cfg.complete_style) {
        .cycle => try cycleStep(e, .back),
        .menu => if (e.cfg.multiline) try cycleStep(e, .back) else try menuBegin(e, .back),
        .list => {},
    }
}

pub fn menuKey(e: *Engine, k: key.Key) !MenuResult {
    if (e.menu.* == null) return .pass;
    switch (k) {
        .tab, .down => try menuMove(e, .fwd),
        .backtab, .up => try menuMove(e, .back),
        .submit, .right => try accept(e),
        .escape, .cancel => try cancel(e),
        else => {
            try cancel(e);
            return .pass;
        },
    }
    return .handled;
}

pub fn endCycleFor(e: *Engine, k: key.Key) void {
    switch (k) {
        .tab, .backtab => {},
        else => e.cycle.* = null,
    }
}

pub fn clear(e: *Engine) void {
    e.cycle.* = null;
    e.menu.* = null;
}

/// Draw the menu rows below the prompt and come back to the prompt's row,
/// using only relative motion: save/restore-cursor records an absolute
/// position, which goes stale the moment drawing at the bottom of the screen
/// scrolls everything up. Written before the prompt repaint, which re-anchors
/// the column with its own `\r`.
pub fn writeMenu(e: *Engine) !void {
    const m = e.menu.* orelse return;
    if (e.cfg.multiline or e.hidden) return;
    const n = m.items.len;
    if (n == 0) return;
    const rows = @min(n, @min(@max(e.cfg.max_listed, 1), max_menu_rows));
    const first = if (m.idx >= rows) m.idx + 1 - rows else 0;
    const last = @min(first + rows, n);
    e.out.clearRetainingCapacity();
    try e.out.appendSlice(e.alloc, "\r\n\x1b[0J");
    var i = first;
    while (i < last) : (i += 1) {
        if (i > first) try e.out.appendSlice(e.alloc, "\r\n");
        try menuRow(e, m.items[i], i == m.idx);
    }
    try render.appendNum(e.out, e.alloc, "\x1b[", last - first, "A");
    try e.term.write(e.out.items);
}

fn completeList(e: *Engine) !void {
    const items = (try gather(e)) orelse return;
    const word = currentWord(e.line);
    if (items.len == 1) return e.line.replaceBack(word.len, items[0]);
    const lcp = longestPrefix(items);
    if (lcp.len > word.len) return e.line.replaceBack(word.len, lcp);
    try listComps(e, items);
}

fn gather(e: *Engine) !?[]const []const u8 {
    const cb = e.cfg.complete orelse {
        e.term.bell();
        return null;
    };
    _ = e.arena.reset(.retain_capacity);
    var comps = config.Completions{ .arena = e.arena.allocator() };
    const line = e.line.text();
    try cb(e.cfg.ctx, line, e.line.cursor, currentWord(e.line), &comps);
    if (comps.items.items.len == 0) {
        e.term.bell();
        return null;
    }
    return comps.items.items;
}

fn cycleStep(e: *Engine, dir: Dir) !void {
    if (e.cycle.* == null) return cycleBegin(e, dir);
    const c = &e.cycle.*.?;
    if (currentWord(e.line).len != c.shown_len) {
        e.cycle.* = null;
        return cycleBegin(e, dir);
    }
    const next = nextIdx(c.idx, c.items.len, dir);
    try e.line.replaceBack(c.shown_len, c.items[next]);
    c.idx = next;
    c.shown_len = c.items[next].len;
}

fn cycleBegin(e: *Engine, dir: Dir) !void {
    const items = (try gather(e)) orelse return;
    const word = currentWord(e.line);
    const idx = if (dir == .back and items.len > 1) items.len - 1 else 0;
    try e.line.replaceBack(word.len, items[idx]);
    if (items.len == 1) return;
    e.menu.* = null;
    e.cycle.* = .{ .items = items, .shown_len = items[idx].len, .idx = idx };
}

fn menuBegin(e: *Engine, dir: Dir) !void {
    const items = (try gather(e)) orelse return;
    const word = currentWord(e.line);
    const saved = try e.arena.allocator().dupe(u8, word);
    const idx = if (dir == .back and items.len > 1) items.len - 1 else 0;
    try e.line.replaceBack(word.len, items[idx]);
    if (items.len == 1) return;
    e.cycle.* = null;
    e.menu.* = .{ .items = items, .saved = saved, .shown_len = items[idx].len, .idx = idx };
}

fn menuMove(e: *Engine, dir: Dir) !void {
    const m = &e.menu.*.?;
    if (currentWord(e.line).len != m.shown_len) return accept(e);
    const next = nextIdx(m.idx, m.items.len, dir);
    try e.line.replaceBack(m.shown_len, m.items[next]);
    m.idx = next;
    m.shown_len = m.items[next].len;
}

fn cancel(e: *Engine) !void {
    const m = e.menu.* orelse return;
    if (m.shown_len <= e.line.cursor) try e.line.replaceBack(m.shown_len, m.saved);
    e.menu.* = null;
    try clearRows(e);
}

fn accept(e: *Engine) !void {
    e.menu.* = null;
    try clearRows(e);
}

fn clearRows(e: *Engine) !void {
    if (e.cfg.multiline or e.hidden) return;
    // Relative motion for the same reason as writeMenu; the redraw that
    // always follows re-anchors the cursor column on the prompt row.
    try e.term.write("\r\n\x1b[0J\x1b[A");
}

fn listComps(e: *Engine, items: []const []const u8) !void {
    if (e.hidden) return;
    try e.term.write("\r\n");
    const shown = @min(items.len, e.cfg.max_listed);
    for (items[0..shown]) |c| try listItem(e, c);
    if (shown < items.len) try more(e, items.len - shown);
    try e.term.write("\r\n");
    e.ml_row.* = 0;
}

fn listItem(e: *Engine, item: []const u8) !void {
    try e.term.write(item);
    try e.term.write("   ");
}

fn more(e: *Engine, n: usize) !void {
    e.out.clearRetainingCapacity();
    try render.appendNum(e.out, e.alloc, "… (", n, " more)");
    try e.term.write(e.out.items);
}

fn menuRow(e: *Engine, item: []const u8, selected: bool) !void {
    const cells = if (e.term.cols > 4) e.term.cols - 4 else 1;
    if (selected) try e.out.appendSlice(e.alloc, "\x1b[7m");
    try e.out.appendSlice(e.alloc, " ");
    try e.out.appendSlice(e.alloc, render.truncCells(item, cells));
    try e.out.appendSlice(e.alloc, " ");
    if (selected) try e.out.appendSlice(e.alloc, "\x1b[0m");
    try e.out.appendSlice(e.alloc, "\x1b[0K");
}

fn nextIdx(idx: usize, len: usize, dir: Dir) usize {
    return switch (dir) {
        .fwd => (idx + 1) % len,
        .back => (idx + len - 1) % len,
    };
}

fn currentWord(line: *const Line) []const u8 {
    const head = line.text()[0..line.cursor];
    const s = if (std.mem.lastIndexOfAny(u8, head, " \t")) |i| i + 1 else 0;
    return head[s..];
}

fn longestPrefix(items: []const []const u8) []const u8 {
    var p = items[0];
    for (items[1..]) |s| {
        var i: usize = 0;
        while (i < p.len and i < s.len and p[i] == s[i]) i += 1;
        p = p[0..utf8Boundary(p, i)];
    }
    return p;
}

fn utf8Boundary(s: []const u8, n: usize) usize {
    var end = n;
    while (end > 0 and end < s.len and unicode.isCont(s[end])) end -= 1;
    return end;
}

test "longest common prefix" {
    const items = [_][]const u8{ "commit", "config", "checkout" };
    try std.testing.expectEqualStrings("c", longestPrefix(&items));
    const two = [_][]const u8{ "config", "configure" };
    try std.testing.expectEqualStrings("config", longestPrefix(&two));
    const same_codepoint = [_][]const u8{ "éclair", "éon" };
    try std.testing.expectEqualStrings("é", longestPrefix(&same_codepoint));
    const split_codepoint = [_][]const u8{ "éclair", "êwork" };
    try std.testing.expectEqualStrings("", longestPrefix(&split_codepoint));
}

fn valueComps(
    _: ?*anyopaque,
    line: []const u8,
    cursor: usize,
    word: []const u8,
    out: *config.Completions,
) anyerror!void {
    const head = line[0 .. cursor - word.len];
    const values = if (std.mem.eql(u8, head, "size "))
        &[_][]const u8{ "256x256", "512x512", "1024x1024" }
    else if (std.mem.eql(u8, head, "stats "))
        &[_][]const u8{ "on", "off" }
    else if (std.mem.eql(u8, head, "live "))
        &[_][]const u8{ "on", "off", "every" }
    else if (std.mem.eql(u8, head, "live every "))
        &[_][]const u8{ "1", "2", "4" }
    else
        &[_][]const u8{};
    for (values) |v| if (std.mem.startsWith(u8, v, word)) try out.add(v);
}

const Harness = struct {
    line: Line,
    arena: std.heap.ArenaAllocator,
    out: std.ArrayList(u8) = .empty,
    term: sys.Terminal,
    in_fd: sys.Fd,
    out_fd: sys.Fd,
    ml_row: usize = 0,
    cycle: ?CycleState = null,
    menu: ?MenuState = null,
    style: config.CompleteStyle,

    fn init(style: config.CompleteStyle) !Harness {
        const in_fd = try sys.devNull();
        errdefer sys.close(in_fd);
        const out_fd = try sys.devNull();
        return .{
            .line = Line.init(std.testing.allocator),
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .term = sys.Terminal.init(in_fd, out_fd),
            .in_fd = in_fd,
            .out_fd = out_fd,
            .style = style,
        };
    }

    fn deinit(self: *Harness) void {
        self.line.deinit();
        self.arena.deinit();
        self.out.deinit(std.testing.allocator);
        sys.close(self.in_fd);
        sys.close(self.out_fd);
    }

    fn engine(self: *Harness) Engine {
        return .{
            .alloc = std.testing.allocator,
            .cfg = .{ .complete = valueComps, .complete_style = self.style },
            .term = &self.term,
            .line = &self.line,
            .arena = &self.arena,
            .out = &self.out,
            .ml_row = &self.ml_row,
            .cycle = &self.cycle,
            .menu = &self.menu,
            .hidden = false,
        };
    }
};

fn expectCycle(h: *Harness, input: []const u8, want: []const []const u8) !void {
    try h.line.setText(input);
    h.cycle = null;
    h.menu = null;
    for (want) |text| {
        var e = h.engine();
        try complete(&e);
        try std.testing.expectEqualStrings(text, h.line.text());
    }
}

test "line-aware completion offers command parameter values" {
    var h = try Harness.init(.cycle);
    defer h.deinit();
    try expectCycle(&h, "size ", &.{ "size 256x256", "size 512x512", "size 1024x1024" });
    try expectCycle(&h, "stats ", &.{ "stats on", "stats off" });
    try expectCycle(&h, "live ", &.{ "live on", "live off", "live every" });
    try expectCycle(&h, "live every ", &.{ "live every 1", "live every 2", "live every 4" });
}

test "line-aware completion filters current word" {
    var h = try Harness.init(.cycle);
    defer h.deinit();
    try expectCycle(&h, "size 2", &.{"size 256x256"});
    try expectCycle(&h, "live e", &.{"live every"});
}

test "menu completion cycles, accepts, and cancels" {
    var h = try Harness.init(.menu);
    defer h.deinit();
    try h.line.setText("size ");
    var e = h.engine();
    try complete(&e);
    try std.testing.expectEqualStrings("size 256x256", h.line.text());
    try std.testing.expect(h.menu != null);
    try std.testing.expect(try menuKey(&e, .tab) == .handled);
    try std.testing.expectEqualStrings("size 512x512", h.line.text());
    try std.testing.expect(try menuKey(&e, .backtab) == .handled);
    try std.testing.expectEqualStrings("size 256x256", h.line.text());
    try std.testing.expect(try menuKey(&e, .submit) == .handled);
    try std.testing.expect(h.menu == null);

    try h.line.setText("size ");
    try complete(&e);
    try std.testing.expect(try menuKey(&e, .escape) == .handled);
    try std.testing.expectEqualStrings("size ", h.line.text());
}

test "typing closes menu and keeps the original word" {
    var h = try Harness.init(.menu);
    defer h.deinit();
    try h.line.setText("size ");
    var e = h.engine();
    try complete(&e);
    try std.testing.expect(try menuKey(&e, .{ .char = '5' }) == .pass);
    try std.testing.expectEqualStrings("size ", h.line.text());
    try std.testing.expect(h.menu == null);
}

test "menu completion renders candidates below the prompt" {
    var h = try Harness.init(.menu);
    defer h.deinit();
    try h.line.setText("size ");
    var e = h.engine();
    try complete(&e);
    try writeMenu(&e);
    try std.testing.expect(std.mem.indexOf(u8, h.out.items, "256x256") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.out.items, "512x512") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.out.items, "\x1b[7m") != null);
}

test "menu drawing uses only relative cursor motion" {
    var h = try Harness.init(.menu);
    defer h.deinit();
    try h.line.setText("size ");
    var e = h.engine();
    try complete(&e);
    try writeMenu(&e);
    // Save/restore-cursor records an absolute position that goes stale when
    // drawing at the bottom of the screen scrolls; rows must instead come
    // back up with a relative move matching the rows drawn.
    try std.testing.expect(std.mem.indexOf(u8, h.out.items, "\x1b[s") == null);
    try std.testing.expect(std.mem.indexOf(u8, h.out.items, "\x1b[u") == null);
    try std.testing.expect(std.mem.startsWith(u8, h.out.items, "\r\n\x1b[0J"));
    try std.testing.expect(std.mem.endsWith(u8, h.out.items, "\x1b[3A")); // 3 rows drawn
}

test "the menu shows at most max_menu_rows rows" {
    var h = try Harness.init(.menu);
    defer h.deinit();
    h.menu = .{
        .items = &.{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" },
        .saved = "",
        .shown_len = 1,
        .idx = 0,
    };
    var e = h.engine();
    try writeMenu(&e); // 10 candidates, default max_listed 100
    try std.testing.expect(std.mem.endsWith(u8, h.out.items, "\x1b[8A"));
}
