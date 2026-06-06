//! vi modal editing: normal-mode key handling, counts, motions, operators,
//! and the insert/normal mode switches. Everything here works on the
//! editor's line and vi-mode fields; history navigation and submit/cancel
//! routing stay in the editor itself.

const std = @import("std");
const key = @import("key.zig");
const sys = @import("sys.zig");
const Editor = @import("editor.zig").Editor;
const Action = Editor.Action;

pub fn normal(ed: *Editor, k: key.Key) !Action {
    switch (k) {
        .char => |cp| try charKey(ed, cp),
        .submit => return .submit,
        .interrupt, .cancel => return .cancel,
        // .eof is a closed input stream (Ctrl-D arrives as .ctrl_d), so it
        // must always end the line or the editor spins on a dead fd.
        .eof => return .eof,
        .left, .backspace => ed.line.left(),
        .right => ed.line.cursor = right(ed, ed.line.cursor),
        .home => ed.line.home(),
        .end => ed.line.end(),
        .escape => resetPending(ed),
        else => {},
    }
    return .cont;
}

fn charKey(ed: *Editor, cp_full: u21) !void {
    if (ed.vi_replace) return replace(ed, cp_full);
    // Non-ASCII can't be a vi command; 0 falls through every arm to a bell.
    const cp: u8 = if (cp_full < 128) @intCast(cp_full) else 0;
    if ((cp >= '1' and cp <= '9') or (cp == '0' and ed.vi_count > 0)) {
        ed.vi_count = ed.vi_count *| 10 +| (cp - '0'); // saturate, never trap
        return;
    }
    // No count exceeds the line length in effect; clamping keeps absurd
    // counts from spinning through billions of no-op motion steps.
    const raw = if (ed.vi_count == 0) 1 else ed.vi_count;
    const count = @min(raw, ed.line.text().len + 1);
    ed.vi_count = 0;
    if (ed.vi_op) |op| {
        ed.vi_op = null;
        return operate(ed, op, cp, count);
    }
    return command(ed, cp, count);
}

fn command(ed: *Editor, cp: u8, count: usize) !void {
    switch (cp) {
        'i' => enterInsert(ed),
        'a' => appendInsert(ed),
        'I' => {
            ed.line.home();
            enterInsert(ed);
        },
        'A' => {
            ed.line.end();
            enterInsert(ed);
        },
        's' => {
            ed.line.deleteFwd();
            enterInsert(ed);
        },
        'x' => try delChars(ed, count),
        'D' => try ed.line.killToEnd(),
        'C' => {
            try ed.line.killToEnd();
            enterInsert(ed);
        },
        'p' => try ed.line.yank(), // pastes at the cursor (vi puts it after)
        '~' => ed.line.swapCase(),
        'r' => ed.vi_replace = true, // replaces one char; a count is ignored
        'd', 'c' => ed.vi_op = cp,
        else => move(ed, cp, count),
    }
}

fn appendInsert(ed: *Editor) void {
    ed.line.right();
    enterInsert(ed);
}

fn move(ed: *Editor, cp: u8, count: usize) void {
    if (motion(ed, cp, count)) |idx| ed.line.cursor = idx else ed.term.bell();
}

fn motion(ed: *Editor, cp: u8, count: usize) ?usize {
    var idx = ed.line.cursor;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        idx = switch (cp) {
            'h' => ed.line.idxLeft(idx),
            'l', ' ' => right(ed, idx),
            'w' => ed.line.idxWordFwd(idx),
            'e' => ed.line.idxWordR(idx),
            'b' => ed.line.idxWordL(idx),
            '0', '^' => 0,
            '$' => lineEnd(ed),
            else => return null,
        };
    }
    return idx;
}

fn right(ed: *Editor, idx: usize) usize {
    const len = ed.line.text().len;
    const next = ed.line.idxRight(idx);
    return if (len > 0 and next >= len) ed.line.idxLeft(len) else next;
}

fn lineEnd(ed: *Editor) usize {
    const len = ed.line.text().len;
    return if (len == 0) 0 else ed.line.idxLeft(len);
}

fn operate(ed: *Editor, op: u8, cp: u8, count: usize) !void {
    if (cp == op) { // dd / cc
        try ed.line.deleteSpan(0, ed.line.text().len);
        if (op == 'c') enterInsert(ed);
        return;
    }
    // `cw` deliberately acts like `dw` (the gap goes too), unlike vi's `ce`.
    const target = if (cp == '$')
        ed.line.text().len
    else
        motion(ed, cp, count) orelse return ed.term.bell();
    const lo = @min(ed.line.cursor, target);
    const hi = @max(ed.line.cursor, target);
    try ed.line.deleteSpan(lo, hi);
    if (op == 'c') enterInsert(ed);
}

fn delChars(ed: *Editor, count: usize) !void {
    const start = ed.line.cursor;
    var stop = start;
    var i: usize = 0;
    while (i < count and stop < ed.line.text().len) : (i += 1) {
        stop = ed.line.idxRight(stop);
    }
    if (stop > start) try ed.line.deleteSpan(start, stop);
}

fn replace(ed: *Editor, cp: u21) !void {
    ed.vi_replace = false;
    if (ed.line.cursor >= ed.line.text().len) return ed.term.bell();
    ed.line.deleteFwd();
    try ed.line.insert(cp);
    ed.line.left();
}

pub fn enterInsert(ed: *Editor) void {
    ed.vi_normal = false;
    ed.term.cursorShape(false);
}

pub fn enterNormal(ed: *Editor) void {
    ed.vi_normal = true;
    if (ed.line.cursor > 0) ed.line.left();
    resetPending(ed);
    ed.term.cursorShape(true);
}

fn resetPending(ed: *Editor) void {
    ed.vi_count = 0;
    ed.vi_op = null;
    ed.vi_replace = false;
}

/// Back to insert mode with no pending count/operator (new line, new prompt).
pub fn reset(ed: *Editor) void {
    ed.vi_normal = false;
    resetPending(ed);
}

// --- tests drive the module directly: set the line up, enter normal mode,
// and send command characters through `normal` ---

fn testEditor(out: sys.Fd) Editor {
    return Editor.initFd(std.testing.allocator, .{ .editing = .vi }, out, out);
}

fn setLine(ed: *Editor, s: []const u8) !void {
    try ed.line.setText(s);
    enterNormal(ed); // cursor lands on the last char, as Esc would put it
}

fn cmd(ed: *Editor, c: u8) !void {
    _ = try normal(ed, .{ .char = c });
}

test "x deletes, 0/D kill to end" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "hello"); // normal mode, cursor on 'o'
    try cmd(&ed, 'x');
    try std.testing.expectEqualStrings("hell", ed.line.text());
    try cmd(&ed, '0');
    try cmd(&ed, 'D');
    try std.testing.expectEqualStrings("", ed.line.text());
}

test "dd clears, dw deletes a word" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "foo bar");
    try cmd(&ed, '0');
    try cmd(&ed, 'd');
    try cmd(&ed, 'w');
    try std.testing.expectEqualStrings("bar", ed.line.text());
    try cmd(&ed, 'd');
    try cmd(&ed, 'd');
    try std.testing.expectEqualStrings("", ed.line.text());
}

test "I/A enter insert at the ends, counts repeat x" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "bcd");
    try cmd(&ed, 'I'); // insert at home
    try std.testing.expect(!ed.vi_normal);
    try std.testing.expectEqual(@as(usize, 0), ed.line.cursor);
    try ed.line.insert('a'); // -> abcd
    enterNormal(&ed);
    try cmd(&ed, 'A'); // append at end
    try std.testing.expectEqual(ed.line.text().len, ed.line.cursor);
    try ed.line.insert('e'); // -> abcde
    try std.testing.expectEqualStrings("abcde", ed.line.text());
    enterNormal(&ed);
    try cmd(&ed, '0');
    try cmd(&ed, '2');
    try cmd(&ed, 'x'); // delete two from start
    try std.testing.expectEqualStrings("cde", ed.line.text());
}

test "r replaces and ~ toggles case" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "cat");
    try cmd(&ed, '0');
    try cmd(&ed, 'r');
    try cmd(&ed, 'b'); // c -> b
    try std.testing.expectEqualStrings("bat", ed.line.text());
    try cmd(&ed, '~'); // b -> B
    try std.testing.expectEqualStrings("Bat", ed.line.text());
}

test "h/l/w/b/$/0 motions move the cursor" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "ab cd");
    try cmd(&ed, '0');
    try std.testing.expectEqual(@as(usize, 0), ed.line.cursor);
    try cmd(&ed, 'l');
    try std.testing.expectEqual(@as(usize, 1), ed.line.cursor);
    try cmd(&ed, 'w'); // start of next word
    try std.testing.expectEqual(@as(usize, 3), ed.line.cursor);
    try cmd(&ed, 'b'); // back a word
    try std.testing.expectEqual(@as(usize, 0), ed.line.cursor);
    try cmd(&ed, '$'); // end: on the last char
    try std.testing.expectEqual(@as(usize, 4), ed.line.cursor);
}

test "dollar lands on last char while d$ deletes through end" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "abcd");
    try cmd(&ed, '$');
    try std.testing.expectEqual(@as(usize, 3), ed.line.cursor);
    try cmd(&ed, 'x');
    try std.testing.expectEqualStrings("abc", ed.line.text());

    try setLine(&ed, "abcd");
    try cmd(&ed, '0');
    try cmd(&ed, 'd');
    try cmd(&ed, '$');
    try std.testing.expectEqualStrings("", ed.line.text());
}

test "a appends, p pastes the last kill" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "ac");
    try cmd(&ed, '0'); // on 'a'
    try cmd(&ed, 'a'); // append after 'a'
    try ed.line.insert('b');
    enterNormal(&ed);
    try std.testing.expectEqualStrings("abc", ed.line.text());
    try cmd(&ed, '0');
    try cmd(&ed, 'D'); // kill "abc"
    try std.testing.expectEqualStrings("", ed.line.text());
    try cmd(&ed, 'p'); // paste it back
    try std.testing.expectEqualStrings("abc", ed.line.text());
}

test "dd and x update the paste register" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "abc");
    try cmd(&ed, 'd');
    try cmd(&ed, 'd');
    try std.testing.expectEqualStrings("", ed.line.text());
    try cmd(&ed, 'p');
    try std.testing.expectEqualStrings("abc", ed.line.text());

    try cmd(&ed, '0');
    try cmd(&ed, 'x');
    try std.testing.expectEqualStrings("bc", ed.line.text());
    try cmd(&ed, 'p');
    try std.testing.expectEqualStrings("abc", ed.line.text());
}

test "cw changes a word, cc changes the whole line" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "foo bar");
    try cmd(&ed, '0');
    try cmd(&ed, 'c'); // operator
    try cmd(&ed, 'w'); // ...over a word: deletes "foo " and enters insert
    try std.testing.expect(!ed.vi_normal);
    try ed.line.insertText("baz");
    enterNormal(&ed);
    try std.testing.expectEqualStrings("bazbar", ed.line.text());
    try cmd(&ed, 'c');
    try cmd(&ed, 'c'); // change the whole line
    try ed.line.insertText("new");
    try std.testing.expectEqualStrings("new", ed.line.text());
}

test "s substitutes a char, C changes to end of line" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "cat");
    try cmd(&ed, '0');
    try cmd(&ed, 's'); // delete char, enter insert
    try ed.line.insert('b'); // -> "bat"
    enterNormal(&ed);
    try std.testing.expectEqualStrings("bat", ed.line.text());
    try cmd(&ed, '0');
    try cmd(&ed, 'l'); // on 'a'
    try cmd(&ed, 'C'); // change to end: kills "at"
    try ed.line.insertText("ig"); // -> "big"
    try std.testing.expectEqualStrings("big", ed.line.text());
}

test "closed input reports EOF even with text on the line" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "abc");
    // .eof is a closed stream, not Ctrl-D; swallowing it would busy-spin.
    try std.testing.expect((try normal(&ed, .eof)) == .eof);
}

test "absurd counts neither overflow nor hang" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(dn);
    defer ed.deinit();
    try setLine(&ed, "ab");
    // Way past usize overflow if accumulated unchecked; must stay safe...
    for (0..25) |_| try cmd(&ed, '9');
    try cmd(&ed, 'l'); // ...and the motion must return promptly, clamped
    try std.testing.expectEqual(@as(usize, 1), ed.line.cursor);
}
