//! Platform backend selector. POSIX and Windows share the same
//! descriptor/terminal surface.

const builtin = @import("builtin");

const impl = switch (builtin.target.os.tag) {
    .windows => @import("backend/windows.zig"),
    else => @import("backend/posix.zig"),
};

pub const Fd = impl.Fd;
pub const Terminal = impl.Terminal;
pub const WriteError = impl.WriteError;

pub const invalid = impl.invalid;

pub const stdin = impl.stdin;
pub const stdout = impl.stdout;

pub const read = impl.read;
pub const writeAll = impl.writeAll;
pub const readToEnd = impl.readToEnd;
pub const close = impl.close;
pub const readable = impl.readable;
pub const isTty = impl.isTty;
pub const openRead = impl.openRead;
pub const openWriteTrunc = impl.openWriteTrunc;
pub const devNull = impl.devNull;
pub const installResize = impl.installResize;
pub const resized = impl.resized;
pub const raiseStop = impl.raiseStop;
