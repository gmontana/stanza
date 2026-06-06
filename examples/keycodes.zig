//! Key-code debugging: print the raw bytes your terminal sends, so keymap
//! issues ("my arrows type letters") can be reported precisely.
//!
//!   zig build keycodes
//!
//! Type keys to see their bytes in hex (printable ASCII shown alongside).
//! Ctrl-C exits.

const std = @import("std");
const stanza = @import("stanza");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var ed = stanza.Editor.init(gpa.allocator(), .{});
    defer ed.deinit();

    if (ed.term.isTty()) try ed.term.enableRaw(); // piped input works too
    defer ed.term.disableRaw();

    std.debug.print("press keys to see their bytes; Ctrl-C quits\r\n", .{});
    while (try ed.src.next()) |b| {
        if (b == 0x03) break; // Ctrl-C
        if (b >= 0x21 and b < 0x7f) {
            std.debug.print("{x:0>2} '{c}'  ", .{ b, b });
        } else {
            std.debug.print("{x:0>2}  ", .{b});
        }
        // One line per burst: break when nothing follows within a beat.
        if (!ed.waitInput(50)) std.debug.print("\r\n", .{});
    }
    std.debug.print("\r\n", .{});
}
