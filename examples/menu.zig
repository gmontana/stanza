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
        .paint = paint,
        .install_resize_handler = true,
    });
    defer ed.deinit();

    try ed.term.write(
        "Completion menu demo. Tab opens/moves, Shift-Tab moves back, Enter accepts.\n" ++
            "After accepting a value, press Enter again to submit the line.\n" ++
            "Commands chain on one line: size <Tab>, Enter, then li<Tab> again. Ctrl-D quits.\n",
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
    // Dispatch on how the head ends, so completion keeps working after any
    // number of "command value" pairs already on the line.
    if (std.mem.endsWith(u8, head, "live every ")) {
        return addMatching(word, out, &.{ "1", "2", "4" });
    }
    if (std.mem.endsWith(u8, head, "size ")) {
        // Details show dimmed in the menu; only the insert text reaches the line.
        const sizes = [_]stanza.Candidate{
            .{ .insert = "256x256", .detail = "fast" },
            .{ .insert = "512x512", .detail = "balanced" },
            .{ .insert = "1024x1024", .detail = "detailed" },
        };
        for (sizes) |c| {
            if (std.mem.startsWith(u8, c.insert, word)) try out.addDetail(c.insert, c.detail);
        }
        return;
    }
    if (std.mem.endsWith(u8, head, "stats ")) return addMatching(word, out, &.{ "on", "off" });
    if (std.mem.endsWith(u8, head, "live ")) return addMatching(word, out, &.{ "on", "off", "every " });
    return addMatching(word, out, &.{ "size ", "stats ", "live ", "quit" });
}

fn addMatching(word: []const u8, out: *stanza.Completions, vals: []const []const u8) !void {
    for (vals) |v| {
        if (std.mem.startsWith(u8, v, word)) try out.add(v);
    }
}

fn paint(_: ?*anyopaque, line: []const u8, out: *stanza.Painter) anyerror!void {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    try out.put(line[0..sp], .{ .color = .cyan, .bold = true });
    try out.plain(line[sp..]);
}
