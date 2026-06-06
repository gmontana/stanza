//! Event-loop usage: a clock keeps ticking while you edit.
//!
//!   zig build async
//!
//! It waits up to one second for input. On a timeout it prints a tick line
//! *above* the prompt with `hide`/`show` — the pattern for any host that
//! emits asynchronous output while a line is being edited. On input it feeds
//! the editor. Enter prints the line; Ctrl-D quits.

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
        if (!ed.waitInput(1000)) {
            ticks += 1;
            try ed.hide(); // erase the prompt row(s)...
            std.debug.print("tick: idle {d}s\r\n", .{ticks}); // ...print above them...
            try ed.show(); // ...and repaint the line being edited
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
