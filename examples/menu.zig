//! Small completion-menu example.
//!
//!   zig build menu
//!
//! Try:
//!   size <Tab>
//!   stats <Tab>
//!   live <Tab>
//!   live every <Tab>

const std = @import("std");
const stanza = @import("stanza");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ed = stanza.Editor.init(alloc, .{
        .editing = .emacs,
        .complete = complete,
        .complete_style = .menu,
        .hint = hint,
        .paint = paint,
        .install_resize_handler = true,
    });
    defer ed.deinit();

    try ed.term.write(
        "Completion menu demo. Tab opens/moves, Shift-Tab moves back, Enter accepts.\n" ++
            "After accepting a value, press Enter again to submit the line.\n" ++
            "Try each one at a fresh prompt: size <Tab>, stats <Tab>, live <Tab>, live every <Tab>. Ctrl-D quits.\n",
    );

    while (true) {
        const line = ed.prompt("stanza> ") catch |err| switch (err) {
            error.Eof => break,
            error.Interrupted => continue,
            else => return err,
        };
        defer alloc.free(line);
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) break;
        try ed.term.write("selected: ");
        try ed.term.write(line);
        try ed.term.write("\n");
    }
}

fn complete(
    _: ?*anyopaque,
    line: []const u8,
    cursor: usize,
    word: []const u8,
    out: *stanza.Completions,
) anyerror!void {
    const head = line[0 .. cursor - word.len];
    if (std.mem.eql(u8, head, "")) return addMatching(word, out, &.{ "size ", "stats ", "live ", "quit" });
    if (std.mem.eql(u8, head, "size ")) {
        return addMatching(word, out, &.{ "256x256", "512x512", "1024x1024" });
    }
    if (std.mem.eql(u8, head, "stats ")) return addMatching(word, out, &.{ "on", "off" });
    if (std.mem.eql(u8, head, "live ")) return addMatching(word, out, &.{ "on", "off", "every " });
    if (std.mem.eql(u8, head, "live every ")) return addMatching(word, out, &.{ "1", "2", "4" });
}

fn addMatching(word: []const u8, out: *stanza.Completions, vals: []const []const u8) !void {
    for (vals) |v| {
        if (std.mem.startsWith(u8, v, word)) try out.add(v);
    }
}

fn hint(_: ?*anyopaque, line: []const u8) ?stanza.Hint {
    if (line.len == 0) return .{ .text = "size, stats, live" };
    if (std.mem.eql(u8, line, "size ")) return .{ .text = "256x256" };
    if (std.mem.eql(u8, line, "stats ")) return .{ .text = "on" };
    if (std.mem.eql(u8, line, "live ")) return .{ .text = "every" };
    if (std.mem.eql(u8, line, "live every ")) return .{ .text = "1" };
    // The command already has its value: nothing left to complete here, so
    // say what the next step is instead of leaving Tab to ring a mute bell.
    for ([_][]const u8{ "size ", "stats ", "live every ", "live " }) |cmd| {
        if (std.mem.startsWith(u8, line, cmd) and line.len > cmd.len) {
            return .{ .text = "  — Enter submits" };
        }
    }
    return null;
}

fn paint(_: ?*anyopaque, line: []const u8, out: *stanza.Painter) anyerror!void {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    try out.put(line[0..sp], .{ .color = .cyan, .bold = true });
    try out.plain(line[sp..]);
}
