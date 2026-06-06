//! Thin POSIX IO helpers shared across Stanza: writing every byte of a buffer
//! to a file descriptor, and detecting whether a descriptor is a terminal.
//!
//! Stanza talks to the tty at the syscall layer so the public API never has to
//! thread an `Io` through. `tcgetattr` doubles as a libc-free `isatty`.

const std = @import("std");
const posix = std.posix;

pub const WriteError = error{WriteFailed};

/// Write every byte of `bytes` to `fd`, retrying short writes and `EINTR`.
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) WriteError!void {
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

/// Read bytes from `fd` into `out` until end of file. Used for history files.
pub fn readToEnd(fd: posix.fd_t, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &chunk);
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..n]);
    }
}

/// Close a file descriptor, ignoring the result. `std.posix.close` was removed
/// in the Io rework, so we go through the syscall layer.
pub fn close(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// Remove a file, ignoring the result. Used to clean up test fixtures.
pub fn unlink(path: [*:0]const u8) void {
    _ = posix.system.unlinkat(posix.AT.FDCWD, path, 0);
}

/// Wait up to `ms` for `fd` to become readable. Used to bound escape-sequence
/// and cursor-report reads. Goes to the syscall layer (not `std.posix.poll`,
/// which retries EINTR) so a signal such as SIGWINCH returns false and wakes
/// the caller. That lets the blocking `prompt` path redraw on a resize.
pub fn readable(fd: posix.fd_t, ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    return posix.system.poll(&fds, 1, ms) > 0;
}

/// True when `fd` refers to a terminal. Goes straight to the syscall layer
/// (not `std.posix.tcgetattr`, which panics on an unexpected errno such as the
/// ENODEV that /dev/null returns) and treats any non-success as "not a tty".
pub fn isTty(fd: posix.fd_t) bool {
    var term: posix.termios = undefined;
    return posix.system.tcgetattr(fd, &term) == 0;
}
