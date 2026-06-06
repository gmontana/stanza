//! Event-loop usage: a clock keeps ticking while you edit.
//!
//!   zig build async
//!
//! It polls stdin with a one-second timeout. On a timeout it bumps an idle
//! counter (shown in the window title, which does not disturb the line); on
//! input it feeds the editor. Enter prints the line; Ctrl-D quits.

const std = @import("std");
const stanza = @import("stanza");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ed = stanza.Editor.init(alloc, .{ .install_resize_handler = true });
    defer ed.deinit();

    try ed.editStart("async ❯ ");
    defer ed.editStop();

    var ticks: usize = 0;
    while (true) {
        var fds = [_]std.posix.pollfd{.{
            .fd = ed.fd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if ((std.posix.poll(&fds, 1000) catch 0) == 0) {
            ticks += 1;
            std.debug.print("\x1b]2;Stanza — idle {d}s\x07", .{ticks}); // window title
            continue;
        }
        switch (ed.editFeed() catch |err| switch (err) {
            error.Eof, error.Interrupted => break,
            else => return err,
        }) {
            .line => |line| {
                defer alloc.free(line);
                std.debug.print("ran after {d}s idle: {s}\r\n", .{ ticks, line });
                ticks = 0;
                try ed.editStart("async ❯ ");
            },
            .more => {},
        }
    }
}
