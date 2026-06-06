//! Multi-line editing: long lines wrap across physical rows instead of
//! scrolling. Run it in a narrow window and type past the edge.
//!
//!   zig build wrap

const std = @import("std");
const stanza = @import("stanza");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ed = stanza.Editor.init(alloc, .{
        .multiline = true,
        .install_resize_handler = true,
    });
    defer ed.deinit();

    std.debug.print("multi-line demo — type a long line; Ctrl-D quits.\n", .{});
    while (true) {
        const line = ed.prompt("wrap ❯ ") catch |err| switch (err) {
            error.Eof => break,
            error.Interrupted => continue,
            else => return err,
        };
        defer alloc.free(line);
        if (std.mem.eql(u8, line, "quit")) break;
        std.debug.print("  ↳ {d} bytes\r\n", .{line.len});
    }
}
