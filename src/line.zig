//! The editable line: UTF-8 text plus a cursor measured in bytes that always
//! rests on a codepoint boundary, with a single-register kill buffer.
//!
//! All mutation goes through here, so the editor stays free of byte
//! bookkeeping. Cursor motion and deletion are codepoint-aware; word motion
//! treats ASCII whitespace as the only boundary.

const std = @import("std");
const unicode = @import("unicode.zig");

pub const Line = struct {
    bytes: std.ArrayList(u8) = .empty,
    kill: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Line {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Line) void {
        self.bytes.deinit(self.alloc);
        self.kill.deinit(self.alloc);
    }

    pub fn text(self: *const Line) []const u8 {
        return self.bytes.items;
    }

    pub fn isEmpty(self: *const Line) bool {
        return self.bytes.items.len == 0;
    }

    pub fn clear(self: *Line) void {
        self.bytes.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn setText(self: *Line, s: []const u8) !void {
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(self.alloc, s);
        self.cursor = self.bytes.items.len;
    }

    pub fn insert(self: *Line, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.bytes.insertSlice(self.alloc, self.cursor, buf[0..n]);
        self.cursor += n;
    }

    pub fn insertText(self: *Line, s: []const u8) !void {
        try self.bytes.insertSlice(self.alloc, self.cursor, s);
        self.cursor += s.len;
    }

    /// Replace `nbytes` immediately before the cursor with `s` (used by
    /// completion, which knows the byte length of the word it replaces).
    pub fn replaceBack(self: *Line, nbytes: usize, s: []const u8) !void {
        const start = self.cursor - nbytes;
        self.removeRange(start, self.cursor);
        self.cursor = start;
        try self.insertText(s);
    }

    pub fn backspace(self: *Line) void {
        if (self.cursor == 0) return;
        const start = self.prevStart(self.cursor);
        self.removeRange(start, self.cursor);
        self.cursor = start;
    }

    pub fn deleteFwd(self: *Line) void {
        if (self.cursor >= self.bytes.items.len) return;
        self.removeRange(self.cursor, self.nextStart(self.cursor));
    }

    pub fn left(self: *Line) void {
        self.cursor = self.prevStart(self.cursor);
    }

    pub fn right(self: *Line) void {
        self.cursor = self.nextStart(self.cursor);
    }

    pub fn home(self: *Line) void {
        self.cursor = 0;
    }

    pub fn end(self: *Line) void {
        self.cursor = self.bytes.items.len;
    }

    pub fn wordLeft(self: *Line) void {
        self.cursor = self.wordLeftIdx(self.cursor);
    }

    pub fn wordRight(self: *Line) void {
        self.cursor = self.wordRightIdx(self.cursor);
    }

    pub fn killToEnd(self: *Line) !void {
        try self.setKill(self.bytes.items[self.cursor..]);
        self.bytes.items.len = self.cursor;
    }

    pub fn killToHome(self: *Line) !void {
        try self.setKill(self.bytes.items[0..self.cursor]);
        self.removeRange(0, self.cursor);
        self.cursor = 0;
    }

    pub fn killWordBack(self: *Line) !void {
        const start = self.wordLeftIdx(self.cursor);
        try self.setKill(self.bytes.items[start..self.cursor]);
        self.removeRange(start, self.cursor);
        self.cursor = start;
    }

    pub fn killWordFwd(self: *Line) !void {
        const stop = self.wordRightIdx(self.cursor);
        try self.setKill(self.bytes.items[self.cursor..stop]);
        self.removeRange(self.cursor, stop);
    }

    pub fn yank(self: *Line) !void {
        if (self.kill.items.len == 0) return;
        try self.insertText(self.kill.items);
    }

    /// Swap the codepoint before the cursor with the one before it, then step
    /// right — the classic readline Ctrl-T behavior.
    pub fn transpose(self: *Line) void {
        var mid = self.cursor;
        if (mid == self.bytes.items.len) mid = self.prevStart(mid);
        if (mid == 0) return;
        const lo = self.prevStart(mid);
        const hi = self.nextStart(mid);
        if (lo == mid or hi == mid) return;
        self.swap3(lo, mid, hi);
        self.cursor = hi;
    }

    // Pure index helpers (do not move the cursor) used by vi motions.
    pub fn idxLeft(self: *const Line, i: usize) usize {
        return self.prevStart(i);
    }

    pub fn idxRight(self: *const Line, i: usize) usize {
        return self.nextStart(i);
    }

    pub fn idxWordL(self: *const Line, i: usize) usize {
        return self.wordLeftIdx(i);
    }

    pub fn idxWordR(self: *const Line, i: usize) usize {
        return self.wordRightIdx(i);
    }

    /// vi `w`: skip the current word then trailing spaces, landing on the start
    /// of the next word (so `dw` removes the gap too).
    pub fn idxWordFwd(self: *const Line, from: usize) usize {
        var i = from;
        const n = self.bytes.items.len;
        while (i < n and !isSpace(self.bytes.items[i])) i = self.nextStart(i);
        while (i < n and isSpace(self.bytes.items[i])) i = self.nextStart(i);
        return i;
    }

    /// Delete the byte range [a, b) into the kill buffer and put the cursor at
    /// `a`. Used by vi operators (`dw`, `d$`, ...).
    pub fn deleteSpan(self: *Line, a: usize, b: usize) !void {
        try self.setKill(self.bytes.items[a..b]);
        self.removeRange(a, b);
        self.cursor = a;
    }

    /// Toggle ASCII case of the codepoint under the cursor, then step right.
    pub fn swapCase(self: *Line) void {
        if (self.cursor >= self.bytes.items.len) return;
        const c = self.bytes.items[self.cursor];
        if (c >= 'a' and c <= 'z') self.bytes.items[self.cursor] = c - 32;
        if (c >= 'A' and c <= 'Z') self.bytes.items[self.cursor] = c + 32;
        self.cursor = self.nextStart(self.cursor);
    }

    fn setKill(self: *Line, s: []const u8) !void {
        self.kill.clearRetainingCapacity();
        try self.kill.appendSlice(self.alloc, s);
    }

    fn removeRange(self: *Line, a: usize, b: usize) void {
        const items = self.bytes.items;
        std.mem.copyForwards(u8, items[a..], items[b..]);
        self.bytes.items.len -= (b - a);
    }

    /// Swap adjacent byte ranges [a,m) and [m,b) in place via three reversals.
    fn swap3(self: *Line, a: usize, m: usize, b: usize) void {
        const items = self.bytes.items[a..b];
        std.mem.reverse(u8, items[0 .. m - a]);
        std.mem.reverse(u8, items[m - a ..]);
        std.mem.reverse(u8, items);
    }

    fn nextStart(self: *const Line, i: usize) usize {
        if (i >= self.bytes.items.len) return self.bytes.items.len;
        return @min(i + unicode.seqLen(self.bytes.items[i]), self.bytes.items.len);
    }

    fn prevStart(self: *const Line, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and unicode.isCont(self.bytes.items[j])) j -= 1;
        return j;
    }

    fn wordLeftIdx(self: *const Line, from: usize) usize {
        var i = from;
        while (i > 0 and isSpace(self.bytes.items[self.prevStart(i)])) i = self.prevStart(i);
        while (i > 0 and !isSpace(self.bytes.items[self.prevStart(i)])) i = self.prevStart(i);
        return i;
    }

    fn wordRightIdx(self: *const Line, from: usize) usize {
        var i = from;
        const n = self.bytes.items.len;
        while (i < n and isSpace(self.bytes.items[i])) i = self.nextStart(i);
        while (i < n and !isSpace(self.bytes.items[i])) i = self.nextStart(i);
        return i;
    }
};

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t';
}

test "insert and backspace ascii" {
    var ln = Line.init(std.testing.allocator);
    defer ln.deinit();
    for ("abc") |c| try ln.insert(c);
    try std.testing.expectEqualStrings("abc", ln.text());
    ln.backspace();
    try std.testing.expectEqualStrings("ab", ln.text());
}

test "cursor motion is codepoint aware" {
    var ln = Line.init(std.testing.allocator);
    defer ln.deinit();
    try ln.setText("a世b");
    ln.home();
    ln.right(); // past 'a'
    ln.right(); // past '世' (3 bytes)
    try std.testing.expectEqual(@as(usize, 4), ln.cursor);
    ln.left();
    try std.testing.expectEqual(@as(usize, 1), ln.cursor);
}

test "malformed UTF-8 still makes cursor progress" {
    var ln = Line.init(std.testing.allocator);
    defer ln.deinit();
    try ln.setText("a\xffb"); // invalid lead byte in the middle
    ln.home();
    ln.right();
    ln.right(); // steps over the bad byte (seqLen treats it as one)
    ln.right();
    try std.testing.expectEqual(@as(usize, 3), ln.cursor);
    ln.left();
    ln.left();
    try std.testing.expectEqual(@as(usize, 1), ln.cursor);
    ln.deleteFwd(); // removes just the bad byte
    try std.testing.expectEqualStrings("ab", ln.text());
}

test "kill to end then yank" {
    var ln = Line.init(std.testing.allocator);
    defer ln.deinit();
    try ln.setText("hello world");
    ln.home();
    ln.wordRight(); // after "hello"
    try ln.killToEnd();
    try std.testing.expectEqualStrings("hello", ln.text());
    try ln.yank();
    try std.testing.expectEqualStrings("hello world", ln.text());
}

test "transpose swaps codepoints" {
    var ln = Line.init(std.testing.allocator);
    defer ln.deinit();
    try ln.setText("ab");
    ln.transpose();
    try std.testing.expectEqualStrings("ba", ln.text());
}

test "vi word-forward and span delete (dw)" {
    var ln = Line.init(std.testing.allocator);
    defer ln.deinit();
    try ln.setText("foo bar");
    ln.home();
    const target = ln.idxWordFwd(ln.cursor); // start of "bar"
    try std.testing.expectEqual(@as(usize, 4), target);
    try ln.deleteSpan(ln.cursor, target); // dw
    try std.testing.expectEqualStrings("bar", ln.text());
}
