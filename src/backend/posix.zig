//! POSIX terminal and file-descriptor backend.

const std = @import("std");
const posix = std.posix;

pub const Fd = posix.fd_t;
pub const invalid: Fd = -1;

pub const WriteError = error{WriteFailed};

var resize_flag = std.atomic.Value(bool).init(false);
var resize_installed = false;

pub fn stdin() Fd {
    return posix.STDIN_FILENO;
}

pub fn stdout() Fd {
    return posix.STDOUT_FILENO;
}

pub const Terminal = struct {
    in: Fd,
    out: Fd,
    orig: ?posix.termios = null,
    cols: usize = 80,

    pub fn init(in: Fd, out: Fd) Terminal {
        return .{ .in = in, .out = out };
    }

    pub fn initDefault() Terminal {
        return init(stdin(), stdout());
    }

    pub fn closeOwned(_: *Terminal) void {}

    pub fn isTty(self: *const Terminal) bool {
        return isTtyFd(self.in) and isTtyFd(self.out);
    }

    pub fn enableRaw(self: *Terminal) !void {
        if (self.orig != null) return;
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
        if (self.orig) |o| _ = posix.system.tcsetattr(self.in, .FLUSH, &o);
        self.orig = null;
    }

    pub fn write(self: *Terminal, bytes: []const u8) WriteError!void {
        try writeAll(self.out, bytes);
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

    pub fn cursorShape(self: *Terminal, block: bool) void {
        self.write(if (block) "\x1b[2 q" else "\x1b[6 q") catch {};
    }

    pub fn cursorReset(self: *Terminal) void {
        self.write("\x1b[0 q") catch {};
    }

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

pub fn read(fd: Fd, out: []u8) !usize {
    return posix.read(fd, out);
}

pub fn writeAll(fd: Fd, bytes: []const u8) WriteError!void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + done, bytes.len - done);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                done += @intCast(rc);
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

pub fn readToEnd(fd: Fd, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try read(fd, &chunk);
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..n]);
    }
}

pub fn close(fd: Fd) void {
    _ = posix.system.close(fd);
}

pub fn readable(fd: Fd, ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    return posix.system.poll(&fds, 1, ms) > 0;
}

pub const isTty = isTtyFd;

fn isTtyFd(fd: Fd) bool {
    // SAFETY: tcgetattr writes the termios struct before any field is read.
    var term: posix.termios = undefined;
    return posix.system.tcgetattr(fd, &term) == 0;
}

pub fn openRead(path: []const u8) !Fd {
    return posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
}

pub fn openWriteTrunc(path: []const u8, mode: u32) !Fd {
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    return posix.openat(posix.AT.FDCWD, path, flags, @intCast(mode));
}

pub fn devNull() !Fd {
    return posix.openat(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
}

pub fn installResize() void {
    if (resize_installed) return;
    resize_installed = true;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = &onWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.WINCH, &act, null);
}

pub fn resized() bool {
    return resize_flag.swap(false, .seq_cst);
}

fn readCol(fd: Fd) !usize {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        if (!readable(fd, 120)) break;
        const r = read(fd, buf[n .. n + 1]) catch break;
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

fn onWinch(_: posix.SIG) callconv(.c) void {
    resize_flag.store(true, .seq_cst);
}

test "resize handler sets the flag and resized() consumes it" {
    _ = resized();
    try std.testing.expect(!resized());
    onWinch(.WINCH);
    try std.testing.expect(resized());
    try std.testing.expect(!resized());
}

test "updateSize falls back to 80 columns without a valid DSR reply" {
    const dn = try devNull();
    defer close(dn);
    var t = Terminal.init(dn, dn);
    t.cols = 7;
    t.updateSize();
    try std.testing.expectEqual(@as(usize, 80), t.cols);
}
