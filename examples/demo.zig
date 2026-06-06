//! Interactive showcase: a fake "git" prompt with completion, hints, syntax
//! highlighting, and a persistent history file.
//!
//!   zig build demo
//!
//! Try: type "co" then Tab, watch the ghost-text hint, press Up/Ctrl-R for
//! history, Ctrl-A/E/K/W/Y to edit, paste a multi-line blob, Ctrl-C to clear a
//! line, Ctrl-D on an empty line to quit.

const std = @import("std");
const stanza = @import("stanza");

const commands = [_][]const u8{
    "add",    "branch", "checkout", "clone",  "commit",
    "config", "diff",   "fetch",    "init",   "log",
    "merge",  "pull",   "push",     "rebase", "stash",
    "status",
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ed = stanza.Editor.init(alloc, .{
        .complete = complete,
        .hint = hint,
        .paint = paint,
        .install_resize_handler = true,
    });
    defer ed.deinit();

    const history_file = ".stanza_demo_history";
    ed.history.load(history_file) catch {};

    std.debug.print(
        "Stanza demo — vi keys: type, Esc for normal mode (hjkl/w/b/x/dw/A…).\n" ++
            "Tab completes, Ctrl-R searches history, Ctrl-D quits.\n",
        .{},
    );
    while (true) {
        const line = ed.prompt("git ❯ ") catch |err| switch (err) {
            error.Eof => break,
            error.Interrupted => continue,
            else => return err,
        };
        defer alloc.free(line);
        if (line.len == 0) continue;
        try ed.history.add(line);
        if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) break;
        std.debug.print("  ↳ ran: git {s}\n", .{line});
    }
    ed.history.save(history_file) catch {};
    std.debug.print("bye.\n", .{});
}

fn complete(_: ?*anyopaque, word: []const u8, out: *stanza.Completions) anyerror!void {
    for (commands) |c| {
        if (std.mem.startsWith(u8, c, word)) try out.add(c);
    }
}

fn hint(_: ?*anyopaque, line: []const u8) ?stanza.Hint {
    if (line.len == 0) return .{ .text = "subcommand…" };
    for (commands) |c| {
        if (c.len > line.len and std.mem.startsWith(u8, c, line)) {
            return .{ .text = c[line.len..] };
        }
    }
    return null;
}

fn paint(_: ?*anyopaque, line: []const u8, out: *stanza.Painter) anyerror!void {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const known = isCommand(line[0..sp]);
    try out.put(line[0..sp], .{ .color = if (known) .green else .red, .bold = known });
    try out.plain(line[sp..]);
}

fn isCommand(word: []const u8) bool {
    for (commands) |c| {
        if (std.mem.eql(u8, c, word)) return true;
    }
    return false;
}
