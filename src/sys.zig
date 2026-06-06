//! Small platform facade used by the editor and history code.

const std = @import("std");
const backend = @import("backend.zig");

pub const Fd = backend.Fd;
pub const WriteError = backend.WriteError;

pub const invalid = backend.invalid;

pub fn stdin() Fd {
    return backend.stdin();
}

pub fn stdout() Fd {
    return backend.stdout();
}

pub fn read(fd: Fd, out: []u8) !usize {
    return backend.read(fd, out);
}

pub fn writeAll(fd: Fd, bytes: []const u8) WriteError!void {
    try backend.writeAll(fd, bytes);
}

pub fn readToEnd(fd: Fd, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try backend.readToEnd(fd, alloc, out);
}

pub fn close(fd: Fd) void {
    backend.close(fd);
}

pub fn unlink(path: [*:0]const u8) void {
    backend.unlink(path);
}

pub fn readable(fd: Fd, ms: i32) bool {
    return backend.readable(fd, ms);
}

pub fn isTty(fd: Fd) bool {
    return backend.isTty(fd);
}

pub fn openRead(path: []const u8) !Fd {
    return backend.openRead(path);
}

pub fn openWriteTrunc(path: []const u8, mode: u32) !Fd {
    return backend.openWriteTrunc(path, mode);
}

pub fn devNull() !Fd {
    return backend.devNull();
}
