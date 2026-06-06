//! Small platform facade used by the editor and history code.

const backend = @import("backend.zig");

pub const Fd = backend.Fd;
pub const Terminal = backend.Terminal;
pub const WriteError = backend.WriteError;

pub const invalid = backend.invalid;

pub const stdin = backend.stdin;
pub const stdout = backend.stdout;
pub const read = backend.read;
pub const writeAll = backend.writeAll;
pub const readToEnd = backend.readToEnd;
pub const close = backend.close;
pub const readable = backend.readable;
pub const isTty = backend.isTty;
pub const openRead = backend.openRead;
pub const openWriteTrunc = backend.openWriteTrunc;
pub const devNull = backend.devNull;
pub const installResize = backend.installResize;
pub const resized = backend.resized;
pub const raiseStop = backend.raiseStop;
