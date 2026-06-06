//! Drawing the prompt line. Stanza renders a single physical row and scrolls
//! it horizontally to keep the cursor visible, which sidesteps the wrapping and
//! magic-margin pitfalls of multi-row redraws.
//!
//! The line is decomposed into glyphs (byte offset, byte length, cell width) so
//! that scrolling, masking, and cursor placement are all cell-accurate for
//! wide and combining characters. Highlighting applies only when the whole line
//! fits; once scrolled, the plain text is shown.

const std = @import("std");
const unicode = @import("unicode.zig");
const config = @import("config.zig");

pub const Glyph = struct { off: usize, len: usize, width: usize };

/// Everything `build` needs, bundled so the call site stays readable and the
/// editor can hand over its reusable scratch buffers. Decoupled from the
/// terminal (takes `cols`, writes bytes into `out`) so it is unit-testable.
pub const DrawArgs = struct {
    cols: usize,
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    glyphs: *std.ArrayList(Glyph),
    paint_buf: *std.ArrayList(u8),
    prompt: []const u8,
    text: []const u8,
    cursor: usize,
    cfg: config.Config,
};

/// Build the escape sequence that repaints the prompt line and places the
/// cursor, leaving the result in `a.out`. The caller writes it to the terminal.
pub fn build(a: DrawArgs) !void {
    try buildGlyphs(a.text, a.cfg.mask, a.glyphs, a.alloc);
    const plen = promptWidth(a.prompt);
    const avail = if (a.cols > plen + 1) a.cols - plen else 1;
    const cur_g = cursorGlyph(a.glyphs.items, a.cursor);
    const win = window(a.glyphs.items, cur_g, avail);
    a.out.clearRetainingCapacity();
    try a.out.appendSlice(a.alloc, "\r");
    try a.out.appendSlice(a.alloc, a.prompt);
    try emitContent(a, win, avail);
    try a.out.appendSlice(a.alloc, "\x1b[0K");
    try moveToCol(a.out, a.alloc, plen + cellsBetween(a.glyphs.items, win.start, cur_g));
}

/// Multi-line variant: the line wraps across physical rows instead of
/// scrolling. This is Stanza's own row-packing renderer: we lay the glyphs out
/// into rows ourselves using their display widths and break each row with an
/// explicit CR/LF, so wrapping never depends on the terminal's autowrap. The
/// previous block is cleared with a single erase-below, and the cursor is
/// placed by moving up from the bottom row. The one carried-over piece of
/// state is `cursor_row` — where the cursor sat last time — so we can return to
/// the top of the block. Masking applies here; highlighting and ghost-text
/// hints are single-line only.
///
/// (A terminal cannot report where the cursor lands after a character fills the
/// last column, so when the cursor itself sits just past a full row we emit one
/// newline to give it a real row — the single unavoidable concession, expressed
/// in our own row model.)
pub fn buildMulti(a: DrawArgs, cursor_row: *usize) !void {
    try buildGlyphs(a.text, a.cfg.mask, a.glyphs, a.alloc);
    const cols = if (a.cols < 1) 1 else a.cols;
    const pw = promptWidth(a.prompt);
    a.out.clearRetainingCapacity();
    if (cursor_row.* > 0) try appendNum(a.out, a.alloc, "\x1b[", cursor_row.*, "A");
    try a.out.appendSlice(a.alloc, "\r\x1b[0J"); // top of block, then clear below
    try a.out.appendSlice(a.alloc, a.prompt);
    const at = try writeWrapped(a, pw, cols);
    if (at.bottom > at.row) try appendNum(a.out, a.alloc, "\x1b[", at.bottom - at.row, "A");
    if (at.col > 0) try appendNum(a.out, a.alloc, "\r\x1b[", at.col, "C") else try a.out.appendSlice(a.alloc, "\r");
    cursor_row.* = at.row;
}

const Where = struct { bottom: usize, row: usize, col: usize };

/// Write the content wrapped into rows. Returns the row the terminal cursor
/// ends on (`bottom`) and the (row, col) the text cursor belongs at.
fn writeWrapped(a: DrawArgs, pw: usize, cols: usize) !Where {
    const gl = a.glyphs.items;
    const cur_g = cursorGlyph(gl, a.cursor);
    var row: usize = 0;
    var col: usize = pw;
    var start: usize = 0; // first glyph of the current row
    var at = Where{ .bottom = 0, .row = 0, .col = pw };
    var found = false;
    var i: usize = 0;
    while (i < gl.len) : (i += 1) {
        if (col + gl[i].width > cols) { // wrap before this glyph
            try flushRow(a, gl, start, i);
            try a.out.appendSlice(a.alloc, "\r\n");
            row += 1;
            col = 0;
            start = i;
        }
        if (i == cur_g) {
            at.row = row;
            at.col = col;
            found = true;
        }
        col += gl[i].width;
    }
    try flushRow(a, gl, start, gl.len);
    at.bottom = row;
    if (!found) { // cursor is at the end of the text
        at.row = row;
        at.col = col;
        if (col >= cols) { // ...past a full row: give it a fresh one
            try a.out.appendSlice(a.alloc, "\r\n");
            at.bottom = row + 1;
            at.row = row + 1;
            at.col = 0;
        }
    }
    return at;
}

fn flushRow(a: DrawArgs, gl: []const Glyph, start: usize, end: usize) !void {
    if (start >= end) return;
    if (a.cfg.mask) |m| {
        var buf: [4]u8 = undefined;
        const mb = maskBytes(m, &buf);
        var k = start;
        while (k < end) : (k += 1) try a.out.appendSlice(a.alloc, mb);
    } else {
        try a.out.appendSlice(a.alloc, a.text[gl[start].off .. gl[end - 1].off + gl[end - 1].len]);
    }
}

/// UTF-8 form of the mask character, falling back to '*' if it cannot encode.
fn maskBytes(m: u21, buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(m, buf) catch {
        buf[0] = '*';
        return buf[0..1];
    };
    return buf[0..n];
}

/// Append `prefix`, the decimal digits of `n`, then `suffix` — the shape of
/// every parameterized escape sequence Stanza emits.
pub fn appendNum(out: *std.ArrayList(u8), alloc: std.mem.Allocator, prefix: []const u8, n: usize, suffix: []const u8) !void {
    try out.appendSlice(alloc, prefix);
    var buf: [20]u8 = undefined;
    try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "{d}", .{n}));
    try out.appendSlice(alloc, suffix);
}

fn emitContent(a: DrawArgs, win: Span, avail: usize) !void {
    const fits = win.start == 0 and win.end == a.glyphs.items.len;
    if (a.cfg.mask) |m| {
        try emitMask(a.out, a.alloc, win, m);
    } else if (a.cfg.paint != null and fits) {
        try paintInto(a);
        try a.out.appendSlice(a.alloc, a.paint_buf.items);
    } else {
        try a.out.appendSlice(a.alloc, visibleBytes(a.text, a.glyphs.items, win));
    }
    try emitHint(a, win, avail);
}

fn emitMask(out: *std.ArrayList(u8), alloc: std.mem.Allocator, win: Span, m: u21) !void {
    var buf: [4]u8 = undefined;
    const mb = maskBytes(m, &buf);
    var i = win.start;
    while (i < win.end) : (i += 1) try out.appendSlice(alloc, mb);
}

fn paintInto(a: DrawArgs) !void {
    a.paint_buf.clearRetainingCapacity();
    var painter = config.Painter{ .buf = a.paint_buf, .alloc = a.alloc };
    try a.cfg.paint.?(a.cfg.ctx, a.text, &painter);
}

fn emitHint(a: DrawArgs, win: Span, avail: usize) !void {
    if (a.cursor != a.text.len) return;
    const hint_fn = a.cfg.hint orelse return;
    const hint = hint_fn(a.cfg.ctx, a.text) orelse return;
    const used = cellsBetween(a.glyphs.items, win.start, win.end);
    if (used >= avail) return;
    const shown = truncCells(hint.text, avail - used);
    if (shown.len == 0) return;
    var painter = config.Painter{ .buf = a.out, .alloc = a.alloc };
    try painter.put(shown, hint.style);
}

fn buildGlyphs(
    text: []const u8,
    mask: ?u21,
    out: *std.ArrayList(Glyph),
    alloc: std.mem.Allocator,
) !void {
    out.clearRetainingCapacity();
    const mask_width = if (mask) |m| unicode.cpWidth(m) else null;
    var i: usize = 0;
    while (i < text.len) {
        const end = @min(i + unicode.seqLen(text[i]), text.len);
        const w = mask_width orelse unicode.cpWidth(unicode.decode(text[i..end]));
        try out.append(alloc, .{ .off = i, .len = end - i, .width = w });
        i = end;
    }
}

fn cursorGlyph(glyphs: []const Glyph, cursor: usize) usize {
    var i: usize = 0;
    while (i < glyphs.len and glyphs[i].off < cursor) i += 1;
    return i;
}

/// The glyph range [start, end) currently scrolled into view.
const Span = struct { start: usize, end: usize };

fn window(glyphs: []const Glyph, cur: usize, avail: usize) Span {
    var start: usize = 0;
    var used = cellsBetween(glyphs, start, cur);
    while (used >= avail and start < cur) {
        used -= glyphs[start].width;
        start += 1;
    }
    var end = start;
    var w: usize = 0;
    while (end < glyphs.len and w + glyphs[end].width <= avail) {
        w += glyphs[end].width;
        end += 1;
    }
    return .{ .start = start, .end = end };
}

fn cellsBetween(glyphs: []const Glyph, a: usize, b: usize) usize {
    var total: usize = 0;
    var i = a;
    while (i < b) : (i += 1) total += glyphs[i].width;
    return total;
}

fn visibleBytes(text: []const u8, glyphs: []const Glyph, win: Span) []const u8 {
    if (win.start >= win.end) return text[0..0];
    const last = glyphs[win.end - 1];
    return text[glyphs[win.start].off .. last.off + last.len];
}

fn moveToCol(out: *std.ArrayList(u8), alloc: std.mem.Allocator, col: usize) !void {
    if (col > 0) {
        try appendNum(out, alloc, "\r\x1b[", col, "C");
    } else {
        try out.appendSlice(alloc, "\r");
    }
}

/// Longest prefix of `text` that fits in `cells` display columns.
pub fn truncCells(text: []const u8, cells: usize) []const u8 {
    var i: usize = 0;
    var w: usize = 0;
    while (i < text.len) {
        const end = @min(i + unicode.seqLen(text[i]), text.len);
        const cw = unicode.cpWidth(unicode.decode(text[i..end]));
        if (w + cw > cells) break;
        w += cw;
        i = end;
    }
    return text[0..i];
}

/// Display width of a prompt, skipping ANSI CSI escape sequences so colored
/// prompts still position the cursor correctly.
fn promptWidth(p: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < p.len) {
        if (p[i] == 0x1b) {
            i = skipEsc(p, i);
            continue;
        }
        const end = @min(i + unicode.seqLen(p[i]), p.len);
        w += unicode.cpWidth(unicode.decode(p[i..end]));
        i = end;
    }
    return w;
}

fn skipEsc(p: []const u8, i: usize) usize {
    var j = i + 1;
    if (j >= p.len) return j;
    if (p[j] == '[') { // CSI: ends at the first final byte
        j += 1;
        while (j < p.len and !(p[j] >= 0x40 and p[j] <= 0x7e)) j += 1;
        if (j < p.len) j += 1;
        return j;
    }
    if (p[j] == ']') { // OSC (titles, hyperlinks): ends at BEL or ST (ESC \)
        j += 1;
        while (j < p.len) : (j += 1) {
            if (p[j] == 0x07) return j + 1;
            if (p[j] == 0x1b and j + 1 < p.len and p[j + 1] == '\\') return j + 2;
        }
        return j;
    }
    return j; // unknown escape: skip just the ESC byte
}

const TestBufs = struct {
    out: std.ArrayList(u8) = .empty,
    glyphs: std.ArrayList(Glyph) = .empty,
    paint: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestBufs, alloc: std.mem.Allocator) void {
        self.out.deinit(alloc);
        self.glyphs.deinit(alloc);
        self.paint.deinit(alloc);
    }
};

fn fuzzBuild(_: void, smith: *std.testing.Smith) !void {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var text: [300]u8 = undefined;
    const n = smith.sliceWithHash(&text, 0);
    const cols: usize = smith.valueRangeAtMostWithHash(u32, 1, 200, 1);
    const args = DrawArgs{
        .cols = cols,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "> ",
        .text = text[0..n],
        .cursor = n,
        .cfg = .{},
    };
    try build(args); // properties: no panic, no overflow on any byte soup
    var row: usize = 0;
    try buildMulti(args, &row);
}

test "fuzz: rendering survives arbitrary text and widths" {
    try std.testing.fuzz({}, fuzzBuild, .{ .corpus = &.{
        "\xff\xfe\xc3plain 世界 \x1b[31m",
        "exactly-ten",
    } });
}

fn renderOps(alloc: std.mem.Allocator) !void {
    var b = TestBufs{};
    defer b.deinit(alloc);
    const args = DrawArgs{
        .cols = 10,
        .alloc = alloc,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "> ",
        .text = "hello world wrap",
        .cursor = 16,
        .cfg = .{},
    };
    try build(args);
    var row: usize = 0;
    try buildMulti(args, &row);
}

test "allocation failures leave no leaks behind" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, renderOps, .{});
}

test "prompt width skips CSI and OSC escape sequences" {
    try std.testing.expectEqual(@as(usize, 2), promptWidth("\x1b[1;32m> \x1b[0m"));
    // OSC 8 hyperlink (ST-terminated) around "link", then "> "
    const linked = "\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\> ";
    try std.testing.expectEqual(@as(usize, 6), promptWidth(linked));
    // OSC window title, BEL-terminated
    try std.testing.expectEqual(@as(usize, 2), promptWidth("\x1b]0;title\x07$ "));
}

test "truncCells cuts at a cell budget without splitting codepoints" {
    try std.testing.expectEqualStrings("abc", truncCells("abcdef", 3));
    try std.testing.expectEqualStrings("世", truncCells("世界", 3)); // 2nd wide char doesn't fit
    try std.testing.expectEqualStrings("", truncCells("abc", 0));
}

test "render shows text and positions cursor" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "> ",
        .text = "hello",
        .cursor = 5,
        .cfg = .{},
    });
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "hello") != null);
    // cursor column = prompt width (2) + "hello" width (5) = 7
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[7C") != null);
}

test "render mask hides the text" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "secret",
        .cursor = 6,
        .cfg = .{ .mask = '*' },
    });
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "******") != null);
}

test "render mask cursor math uses the mask character width" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "ab",
        .cursor = 2,
        .cfg = .{ .mask = '世' },
    });
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "世世") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[4C") != null);
}

test "render scrolls a long line to keep the cursor visible" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 10,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "abcdefghijklmnop",
        .cursor = 16,
        .cfg = .{},
    });
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "hijklmnop") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "abc") == null);
}

fn hintCb(_: ?*anyopaque, line: []const u8) ?config.Hint {
    _ = line;
    return .{ .text = "-rest" }; // default style is dim gray (SGR 90)
}

fn paintCb(_: ?*anyopaque, line: []const u8, out: *config.Painter) anyerror!void {
    try out.put(line, .{ .color = .green, .bold = true });
}

test "render shows ghost-text hint at end of line" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "cmd",
        .cursor = 3, // at end -> hint shows
        .cfg = .{ .hint = hintCb },
    });
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "-rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[90m") != null);
}

test "render hint hidden when cursor is not at end" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "cmd",
        .cursor = 1, // mid-line -> no hint
        .cfg = .{ .hint = hintCb },
    });
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "-rest") == null);
}

test "render applies highlight when the line fits" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "cmd",
        .cursor = 3,
        .cfg = .{ .paint = paintCb },
    });
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[1;32m") != null); // bold green
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "cmd") != null);
}

test "multiline: single row places cursor after prompt + text" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var row: usize = 0;
    try buildMulti(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "> ",
        .text = "hi",
        .cursor = 2,
        .cfg = .{},
    }, &row);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "> hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[4C") != null); // col 4
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "A") == null); // no row move
    try std.testing.expectEqual(@as(usize, 0), row);
}

test "multiline: wraps with an explicit CRLF, cursor on the bottom row" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var row: usize = 0;
    try buildMulti(.{
        .cols = 10,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "abcdefghijklmno", // 15 cols over width 10 -> 2 rows
        .cursor = 15,
        .cfg = .{},
    }, &row);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\r\n") != null); // our explicit break
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[5C") != null); // col 5 on row 1
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[1A") == null); // already bottom
    try std.testing.expectEqual(@as(usize, 1), row);
}

test "multiline: cursor past a full row gets its own line" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var row: usize = 0;
    try buildMulti(.{
        .cols = 10,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "abcdefghij", // exactly one full row
        .cursor = 10,
        .cfg = .{},
    }, &row);
    try std.testing.expect(std.mem.count(u8, b.out.items, "\r\n") >= 1); // margin newline
    try std.testing.expect(std.mem.endsWith(u8, b.out.items, "\r")); // cursor at col 0
    try std.testing.expectEqual(@as(usize, 1), row);
}

test "multiline: mid-line cursor moves up from the bottom row" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var row: usize = 0;
    try buildMulti(.{
        .cols = 10,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "abcdefghijklmno",
        .cursor = 5, // row 0, col 5
        .cfg = .{},
    }, &row);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[1A") != null); // up one row
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[5C") != null);
    try std.testing.expectEqual(@as(usize, 0), row);
}

test "multiline: redraw returns to the top of the previous block" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var row: usize = 0;
    const wide = DrawArgs{
        .cols = 10,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "abcdefghijklmno",
        .cursor = 15,
        .cfg = .{},
    };
    try buildMulti(wide, &row); // first render: 2 rows, cursor ends on row 1
    try std.testing.expectEqual(@as(usize, 1), row);
    var short = wide;
    short.text = "x";
    short.cursor = 1;
    try buildMulti(short, &row); // buildMulti clears out itself
    try std.testing.expect(std.mem.startsWith(u8, b.out.items, "\x1b[1A")); // up to the top first
    try std.testing.expectEqual(@as(usize, 0), row);
}

test "multiline: mask hides text across wrapped rows" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var row: usize = 0;
    try buildMulti(.{
        .cols = 5,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "secret", // 6 cols over width 5 -> wraps, all masked
        .cursor = 6,
        .cfg = .{ .mask = '*' },
    }, &row);
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "secret") == null);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, b.out.items, "*"));
}

test "render tolerates malformed UTF-8" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    try build(.{
        .cols = 80,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "> ",
        .text = "a\xff\xfeb", // two invalid bytes mid-line
        .cursor = 4,
        .cfg = .{},
    });
    // Each bad byte becomes one replacement-width glyph; no crash, no skew:
    // cursor column = prompt (2) + 4 one-cell glyphs.
    try std.testing.expect(std.mem.indexOf(u8, b.out.items, "\x1b[6C") != null);
}

test "multiline: redraw after a width change stays consistent" {
    const a = std.testing.allocator;
    var b = TestBufs{};
    defer b.deinit(a);
    var row: usize = 0;
    var args = DrawArgs{
        .cols = 10,
        .alloc = a,
        .out = &b.out,
        .glyphs = &b.glyphs,
        .paint_buf = &b.paint,
        .prompt = "",
        .text = "abcdefghijklmno", // 15 cells
        .cursor = 15,
        .cfg = .{},
    };
    try buildMulti(args, &row); // 2 rows at width 10, cursor on row 1
    try std.testing.expectEqual(@as(usize, 1), row);
    args.cols = 5; // terminal narrowed (SIGWINCH)
    try buildMulti(args, &row); // 3 rows + a margin row for the end cursor
    try std.testing.expect(std.mem.startsWith(u8, b.out.items, "\x1b[1A")); // back to the old top
    try std.testing.expectEqual(@as(usize, 3), row);
}
