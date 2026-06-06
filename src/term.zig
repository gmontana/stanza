//! Terminal control: enter and leave raw mode, query the column width via the
//! cursor-position report (so we need neither libc nor ioctl), toggle
//! bracketed paste, and optionally surface SIGWINCH through a resize flag.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");

var resize_flag = std.atomic.Value(bool).init(false);

pub const Terminal = struct {
    in: posix.fd_t,
    out: posix.fd_t,
    orig: ?posix.termios = null,
    cols: usize = 80,

    pub fn init(in: posix.fd_t, out: posix.fd_t) Terminal {
        return .{ .in = in, .out = out };
    }

    pub fn isTty(self: *const Terminal) bool {
        return sys.isTty(self.in) and sys.isTty(self.out);
    }

    pub fn enableRaw(self: *Terminal) !void {
        if (self.orig != null) return; // already raw; keep the saved cooked state
        const orig = try posix.tcgetattr(self.in);
        self.orig = orig;
        var raw = orig;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(self.in, .FLUSH, raw);
    }

    pub fn disableRaw(self: *Terminal) void {
        if (self.orig) |o| posix.tcsetattr(self.in, .FLUSH, o) catch {};
        self.orig = null;
    }

    pub fn write(self: *Terminal, bytes: []const u8) sys.WriteError!void {
        try sys.writeAll(self.out, bytes);
    }

    pub fn bell(self: *Terminal) void {
        self.write("\x07") catch {};
    }

    pub fn pasteOn(self: *Terminal) void {
        self.write("\x1b[?2004h") catch {};
    }

    pub fn pasteOff(self: *Terminal) void {
        self.write("\x1b[?2004l") catch {};
    }

    /// Set the cursor to a steady block (vi normal) or bar (insert/default).
    pub fn cursorShape(self: *Terminal, block: bool) void {
        self.write(if (block) "\x1b[2 q" else "\x1b[6 q") catch {};
    }

    /// Restore the terminal's default cursor shape.
    pub fn cursorReset(self: *Terminal) void {
        self.write("\x1b[0 q") catch {};
    }

    /// Refresh `cols` from the terminal, defaulting to 80 if it does not
    /// reply. (On a tty that ignores DSR the probe may leave the cursor at the
    /// right edge; the `\r` of the next redraw recovers it.)
    pub fn updateSize(self: *Terminal) void {
        self.cols = self.queryCols() catch 80;
        if (self.cols == 0) self.cols = 80;
    }

    fn queryCols(self: *Terminal) !usize {
        const start = try self.cursorCol();
        try self.write("\x1b[999C");
        const wide = try self.cursorCol();
        if (wide > start) {
            var back: [16]u8 = undefined;
            try self.write(try std.fmt.bufPrint(&back, "\x1b[{d}D", .{wide - start}));
        }
        return wide;
    }

    fn cursorCol(self: *Terminal) !usize {
        try self.write("\x1b[6n");
        return readCol(self.in);
    }
};

fn readCol(fd: posix.fd_t) !usize {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        if (!sys.readable(fd, 120)) break; // tty that ignores DSR: don't hang
        const r = posix.read(fd, buf[n .. n + 1]) catch break;
        if (r == 0 or buf[n] == 'R') break;
        n += 1;
    }
    const semi = std.mem.lastIndexOfScalar(u8, buf[0..n], ';') orelse return error.BadReply;
    return parseNum(buf[semi + 1 .. n]);
}

fn parseNum(s: []const u8) usize {
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

var resize_installed = false;

/// Install the SIGWINCH handler that records terminal resizes. This is opt-in
/// because it is process-wide and replaces any handler the host had installed.
pub fn installResize() void {
    if (resize_installed) return;
    resize_installed = true;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = &onWinch },
        .mask = posix.sigemptyset(),
        .flags = 0, // no SA_RESTART: the interrupted poll is the wake-up
    };
    posix.sigaction(.WINCH, &act, null);
}

/// Consume and clear the pending-resize flag.
pub fn resized() bool {
    return resize_flag.swap(false, .seq_cst);
}

fn onWinch(_: posix.SIG) callconv(.c) void {
    resize_flag.store(true, .seq_cst);
}

test "resize handler sets the flag and resized() consumes it" {
    _ = resized(); // clear any prior state
    try std.testing.expect(!resized());
    onWinch(.WINCH); // simulate a SIGWINCH delivery
    try std.testing.expect(resized());
    try std.testing.expect(!resized()); // one-shot: cleared after reading
}

test "updateSize falls back to 80 columns without a valid DSR reply" {
    const dn = try posix.openat(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(dn);
    var t = Terminal.init(dn, dn);
    t.cols = 7; // bogus, to check updateSize replaces it
    t.updateSize(); // no terminal answers \x1b[6n -> must not hang, falls back
    try std.testing.expectEqual(@as(usize, 80), t.cols);
}
