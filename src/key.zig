//! Terminal input: a buffered byte source plus a decoder that turns raw bytes
//! (printable UTF-8, control chars, CSI/SS3 escapes, and bracketed-paste
//! markers) into the semantic `Key` events the editor acts on.
//!
//! The mapping here is Stanza's default keymap; it follows the familiar
//! readline/Emacs bindings. The decoder consumes buffered/ready bytes, with a
//! short grace period for a lone Escape so split escape sequences survive SSH
//! or ConPTY packet boundaries.

const std = @import("std");
const unicode = @import("unicode.zig");
const sys = @import("sys.zig");

/// How long to wait for the rest of an escape sequence before treating a lone
/// Escape as the Escape key (matters for vi normal mode).
const esc_timeout_ms: i32 = 30;
const max_csi_bytes: usize = 32;

pub const Key = union(enum) {
    char: u21,
    submit,
    tab,
    backtab,
    backspace,
    del_fwd,
    ctrl_d,
    left,
    right,
    up,
    down,
    home,
    end,
    word_left,
    word_right,
    kill_to_end,
    kill_to_home,
    kill_word_back,
    kill_word_fwd,
    yank,
    transpose,
    clear,
    search_back,
    paste_begin,
    interrupt,
    cancel,
    suspend_proc,
    escape,
    ignore,
    eof,
};

/// A buffered reader over a raw file descriptor that yields bytes one at a
/// time. `next` may block and is used for plain non-tty reads; the decoder uses
/// readiness checks so incomplete sequences can remain buffered.
pub const Source = struct {
    fd: sys.Fd,
    buf: [256]u8 = @splat(0),
    len: usize = 0,
    pos: usize = 0,
    eof: bool = false,

    pub fn next(self: *Source) !?u8 {
        if (self.eof and self.pos >= self.len) return null;
        if (self.pos >= self.len) {
            self.len = try sys.read(self.fd, &self.buf);
            self.pos = 0;
            if (self.len == 0) self.eof = true;
        }
        if (self.len == 0) return null;
        defer self.pos += 1;
        return self.buf[self.pos];
    }

    pub fn nextAvailable(self: *Source) !?u8 {
        if (!try self.ensureAvailable(1)) return null;
        defer self.consume(1);
        return self.buf[self.pos];
    }

    pub fn ended(self: *const Source) bool {
        return self.eof and self.pos >= self.len;
    }

    fn available(self: *const Source) []const u8 {
        return self.buf[self.pos..self.len];
    }

    fn consume(self: *Source, n: usize) void {
        self.pos += n;
        if (self.pos >= self.len) {
            self.pos = 0;
            self.len = 0;
        }
    }

    fn ensureAvailable(self: *Source, n: usize) !bool {
        while (self.available().len < n and !self.eof) {
            if (!try self.refillAvailable()) break;
        }
        return self.available().len >= n;
    }

    fn ensureTimed(self: *Source, n: usize, ms: i32) !bool {
        while (self.available().len < n and !self.eof) {
            self.compact();
            if (self.eof or self.len == self.buf.len) break;
            if (!sys.readable(self.fd, ms)) break;
            const got = try sys.read(self.fd, self.buf[self.len..]);
            if (got == 0) {
                self.eof = true;
                break;
            }
            self.len += got;
        }
        return self.available().len >= n;
    }

    fn refillAvailable(self: *Source) !bool {
        self.compact();
        if (self.eof or self.len == self.buf.len) return false;
        if (!sys.readable(self.fd, 0)) return false;
        const n = try sys.read(self.fd, self.buf[self.len..]);
        if (n == 0) {
            self.eof = true;
            return false;
        }
        self.len += n;
        return true;
    }

    fn compact(self: *Source) void {
        if (self.pos == 0) return;
        if (self.pos >= self.len) {
            self.pos = 0;
            self.len = 0;
            return;
        }
        const rest = self.len - self.pos;
        std.mem.copyForwards(u8, self.buf[0..rest], self.buf[self.pos..self.len]);
        self.pos = 0;
        self.len = rest;
    }
};

/// Decode one complete key without an unbounded wait. Returns null when the
/// buffered bytes are a partial UTF-8 or escape sequence and the descriptor has
/// no additional bytes ready, except that a lone Escape gets `esc_timeout_ms`
/// for a possible continuation byte.
pub fn decode(src: *Source) !?Key {
    if (!try src.ensureAvailable(1)) return if (src.ended()) .eof else null;
    const b = src.available()[0];
    if (b == 0x1b) return decodeEsc(src);
    if (b < 0x20 or b == 0x7f) {
        src.consume(1);
        return decodeCtrl(b);
    }
    return try decodeChar(src, b);
}

fn decodeChar(src: *Source, first: u8) !?Key {
    var buf: [4]u8 = undefined;
    buf[0] = first;
    const len = @min(unicode.seqLen(first), buf.len);
    if (len > 1 and !try src.ensureAvailable(len) and !src.eof) return null;
    const n = @min(src.available().len, len);
    @memcpy(buf[0..n], src.available()[0..n]);
    src.consume(n);
    return .{ .char = unicode.decode(buf[0..n]) };
}

fn decodeCtrl(b: u8) Key {
    return switch (b) {
        0x0d, 0x0a => .submit,
        0x09 => .tab,
        0x7f, 0x08 => .backspace,
        0x01 => .home,
        0x05 => .end,
        0x02 => .left,
        0x06 => .right,
        0x0b => .kill_to_end,
        0x15 => .kill_to_home,
        0x17 => .kill_word_back,
        0x19 => .yank,
        0x14 => .transpose,
        0x0c => .clear,
        0x10 => .up,
        0x0e => .down,
        0x12 => .search_back,
        0x07 => .cancel,
        0x03 => .interrupt,
        0x04 => .ctrl_d,
        0x1a => .suspend_proc,
        else => .ignore,
    };
}

fn decodeEsc(src: *Source) !?Key {
    if (!try src.ensureAvailable(2)) {
        if (src.available().len == 1 and !src.ended()) {
            _ = try src.ensureTimed(2, esc_timeout_ms);
        }
    }
    if (src.available().len < 2) {
        src.consume(1);
        return .escape;
    }
    const b = src.available()[1];
    return switch (b) {
        '[' => try decodeCsi(src),
        'O' => try decodeSs3(src),
        else => {
            src.consume(2);
            return decodeAlt(b);
        },
    };
}

fn decodeAlt(b: u8) Key {
    return switch (b) {
        'b', 'B' => .word_left,
        'f', 'F' => .word_right,
        'd', 'D' => .kill_word_fwd,
        0x7f, 0x08 => .kill_word_back,
        else => .ignore,
    };
}

fn decodeCsi(src: *Source) !?Key {
    var params: [8]u8 = undefined;
    var n: usize = 0;
    var i: usize = 2; // ESC [
    while (true) : (i += 1) {
        if (!try src.ensureAvailable(i + 1)) {
            if (src.eof) {
                src.consume(src.available().len);
                return .ignore;
            }
            return null;
        }
        const b = src.available()[i];
        if (b >= 0x40 and b <= 0x7e) {
            src.consume(i + 1);
            return csiFinal(b, params[0..n]);
        }
        if (n < params.len) {
            params[n] = b;
            n += 1;
        }
        if (i + 1 >= max_csi_bytes) {
            src.consume(i + 1);
            return .ignore;
        }
    }
}

fn csiFinal(final: u8, params: []const u8) Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => if (ctrlMod(params)) Key.word_right else .right,
        'D' => if (ctrlMod(params)) Key.word_left else .left,
        'H' => .home,
        'F' => .end,
        'Z' => .backtab,
        '~' => csiTilde(params),
        else => .ignore,
    };
}

fn csiTilde(params: []const u8) Key {
    return switch (leadingNum(params)) {
        1, 7 => .home,
        4, 8 => .end,
        3 => .del_fwd,
        200 => .paste_begin,
        else => .ignore,
    };
}

fn decodeSs3(src: *Source) !?Key {
    if (!try src.ensureAvailable(3)) {
        if (!src.eof) return null;
        src.consume(src.available().len);
        return .ignore;
    }
    const b = src.available()[2];
    src.consume(3);
    return switch (b) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => .ignore,
    };
}

/// True when a CSI parameter list carries the Ctrl modifier, e.g. "1;5".
/// The parameter after the ';' is 1 plus a bitmask in which Ctrl is 4, so
/// combinations like Ctrl+Alt ("1;7") count too.
fn ctrlMod(params: []const u8) bool {
    const semi = std.mem.lastIndexOfScalar(u8, params, ';') orelse return false;
    const mod = leadingNum(params[semi + 1 ..]);
    return mod >= 1 and (mod - 1) & 4 != 0;
}

fn leadingNum(params: []const u8) usize {
    var v: usize = 0;
    for (params) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn decodeBytes(bytes: []const u8) !Key {
    // Pre-fill the buffer so decoding never touches the (unused) descriptor;
    // complete sequences always fit, so no read is attempted.
    var src = Source{ .fd = sys.invalid };
    @memcpy(src.buf[0..bytes.len], bytes);
    src.len = bytes.len;
    return (try decode(&src)) orelse error.TestUnexpectedResult;
}

test "decode control keys and CSI sequences" {
    const tag = std.meta.activeTag;
    try std.testing.expect(tag(try decodeBytes("\r")) == .submit);
    try std.testing.expect(tag(try decodeBytes("\t")) == .tab);
    try std.testing.expect(tag(try decodeBytes("\x01")) == .home); // Ctrl-A
    try std.testing.expect(tag(try decodeBytes("\x17")) == .kill_word_back); // Ctrl-W
    try std.testing.expect(tag(try decodeBytes("\x12")) == .search_back); // Ctrl-R
    try std.testing.expect(tag(try decodeBytes("\x1b[A")) == .up);
    try std.testing.expect(tag(try decodeBytes("\x1b[D")) == .left);
    try std.testing.expect(tag(try decodeBytes("\x1b[3~")) == .del_fwd);
    try std.testing.expect(tag(try decodeBytes("\x1b[1;5C")) == .word_right); // Ctrl-Right
    try std.testing.expect(tag(try decodeBytes("\x1b[1;13D")) == .word_left); // Ctrl-Alt-Left
    try std.testing.expect(tag(try decodeBytes("\x1b[1;2C")) == .right); // Shift-Right: no Ctrl
    try std.testing.expect(tag(try decodeBytes("\x1b[200~")) == .paste_begin);
    try std.testing.expect(tag(try decodeBytes("\x1bb")) == .word_left); // Alt-b
    try std.testing.expect(tag(try decodeBytes("\x1b[B")) == .down);
    try std.testing.expect(tag(try decodeBytes("\x1b[F")) == .end);
    try std.testing.expect(tag(try decodeBytes("\x7f")) == .backspace);
    try std.testing.expect(tag(try decodeBytes("\x08")) == .backspace); // Ctrl-H
    try std.testing.expect(tag(try decodeBytes("\x1bOC")) == .right); // SS3 right
    try std.testing.expect(tag(try decodeBytes("\x1b[Z")) == .backtab);
    try std.testing.expect(tag(try decodeBytes("\x04")) == .ctrl_d);
    try std.testing.expect(tag(try decodeBytes("\x1a")) == .suspend_proc); // Ctrl-Z
}

test "decode a multibyte codepoint" {
    switch (try decodeBytes("é")) { // U+00E9, two UTF-8 bytes
        .char => |cp| try std.testing.expectEqual(@as(u21, 0xE9), cp),
        else => return error.TestUnexpectedResult,
    }
}

test "decode keeps partial sequences buffered" {
    var src = Source{ .fd = sys.invalid };

    src.buf[0] = 0xc3; // first byte of "é"
    src.len = 1;
    try std.testing.expect((try decode(&src)) == null);
    try std.testing.expectEqual(@as(usize, 0), src.pos);
    src.buf[1] = 0xa9;
    src.len = 2;
    switch ((try decode(&src)) orelse return error.TestUnexpectedResult) {
        .char => |cp| try std.testing.expectEqual(@as(u21, 0xE9), cp),
        else => return error.TestUnexpectedResult,
    }

    const csi = "\x1b[";
    @memcpy(src.buf[0..csi.len], csi);
    src.len = csi.len;
    src.pos = 0;
    try std.testing.expect((try decode(&src)) == null);
    try std.testing.expectEqual(@as(usize, 0), src.pos);
    src.buf[csi.len] = 'D';
    src.len = csi.len + 1;
    const left = (try decode(&src)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.activeTag(left) == .left);
}

test "decode resolves a lone escape immediately" {
    var src = Source{ .fd = sys.invalid };
    src.buf[0] = 0x1b;
    src.len = 1;
    const esc = (try decode(&src)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.activeTag(esc) == .escape);
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) !void {
    var src = Source{ .fd = sys.invalid, .eof = true };
    const n = smith.sliceWithHash(&src.buf, 0);
    src.len = n;
    // Properties: never panics, never blocks (eof short-circuits the Esc
    // grace), and every decoded key consumed at least one byte.
    var keys: usize = 0;
    while (try decode(&src)) |k| {
        if (std.meta.activeTag(k) == .eof) break;
        keys += 1;
        try std.testing.expect(keys <= n);
    }
}

test "fuzz: decode terminates on arbitrary byte streams" {
    try std.testing.fuzz({}, fuzzDecode, .{ .corpus = &.{
        "\x1b[1;5C\x1b[200~abc\x1b[201~",
        "\x1b\x1b[A\xc3\xa9\xff\xfe\x1bOZ",
        "\x1b[99999999999999999999~\x7f\x00",
        "\x1b[",
    } });
}

test "incomplete escape sequences resolve without hanging" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var src = Source{ .fd = dn }; // reads return 0 once the buffer drains
    const head = "\x1b[";
    @memcpy(src.buf[0..head.len], head);
    src.len = head.len;
    src.eof = true;
    // CSI introducer with no final byte: input ends -> ignored, not a hang.
    try std.testing.expect(std.meta.activeTag((try decode(&src)).?) == .ignore);
    // A lone ESC at end of input decodes as the Escape key.
    src.buf[0] = 0x1b;
    src.len = 1;
    src.pos = 0;
    src.eof = false;
    try std.testing.expect(std.meta.activeTag((try decode(&src)).?) == .escape);
}
