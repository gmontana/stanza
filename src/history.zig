//! Command history: an ordered, de-duplicated, size-bounded list of past
//! entries with optional persistence to a plain newline-delimited file.
//!
//! Navigation state (which entry is showing) lives in the editor; this owns
//! only the store and the lookups it needs, including reverse search.

const std = @import("std");
const sys = @import("sys.zig");

pub const History = struct {
    items: std.ArrayList([]u8) = .empty,
    max: usize,
    alloc: std.mem.Allocator,
    /// How many leading entries are already persisted (see `appendNew`).
    synced: usize = 0,

    pub fn init(alloc: std.mem.Allocator, max: usize) History {
        return .{ .alloc = alloc, .max = if (max == 0) 1 else max };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |e| self.alloc.free(e);
        self.items.deinit(self.alloc);
    }

    pub fn len(self: *const History) usize {
        return self.items.items.len;
    }

    pub fn at(self: *const History, i: usize) []const u8 {
        return self.items.items[i];
    }

    /// Append `entry`, ignoring empties and immediate duplicates, evicting the
    /// oldest entry when the cap is exceeded.
    pub fn add(self: *History, entry: []const u8) !void {
        if (entry.len == 0 or self.lastEquals(entry)) return;
        const dup = try self.alloc.dupe(u8, entry);
        errdefer self.alloc.free(dup);
        try self.items.append(self.alloc, dup);
        // O(n) shift per eviction — deliberate; fine at the ~1000-entry caps
        // history runs at, and it keeps the storage a plain list.
        if (self.items.items.len > self.max) self.evictOldest();
    }

    fn evictOldest(self: *History) void {
        self.alloc.free(self.items.orderedRemove(0));
        self.synced -|= 1; // the persisted watermark shifted down with it
    }

    /// Change the retention cap at runtime, evicting the oldest entries if
    /// the history already exceeds it.
    pub fn setMax(self: *History, max: usize) void {
        self.max = if (max == 0) 1 else max;
        while (self.items.items.len > self.max) self.evictOldest();
    }

    /// Index of the most recent entry containing `term`, searching strictly
    /// older than `before`. Null when there is no match.
    pub fn searchBack(self: *const History, term: []const u8, before: usize) ?usize {
        if (term.len == 0) return null;
        var i = @min(before, self.items.items.len);
        while (i > 0) {
            i -= 1;
            if (std.mem.indexOf(u8, self.items.items[i], term) != null) return i;
        }
        return null;
    }

    /// Load entries from `path`. A missing file is not an error; anything
    /// else (permissions, bad path) propagates so the host can report it.
    pub fn load(self: *History, path: []const u8) !void {
        const fd = sys.openRead(path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer sys.close(fd);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        try sys.readToEnd(fd, self.alloc, &buf);
        var it = std.mem.splitScalar(u8, buf.items, '\n');
        while (it.next()) |line| try self.add(line);
        self.synced = self.items.items.len;
    }

    /// Write all entries to `path`, newline-delimited, creating or truncating.
    /// Note this clobbers entries another instance appended meanwhile; use
    /// `appendNew` when several instances share one history file.
    pub fn save(self: *History, path: []const u8) !void {
        const fd = try sys.openWriteTrunc(path, 0o600);
        defer sys.close(fd);
        for (self.items.items) |e| {
            try sys.writeAll(fd, e);
            try sys.writeAll(fd, "\n");
        }
        self.synced = self.items.items.len;
    }

    /// Append only the entries added since the last `load`/`save`/`appendNew`
    /// to `path`. Appends are atomic at the OS level, so concurrent instances
    /// sharing one history file interleave instead of overwriting each other.
    pub fn appendNew(self: *History, path: []const u8) !void {
        if (self.synced >= self.items.items.len) return;
        const fd = try sys.openAppend(path, 0o600);
        defer sys.close(fd);
        // One write per entry, newline included: O_APPEND makes each write
        // land atomically at the end, so a concurrent instance cannot wedge
        // its entry between this one and its line terminator.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        for (self.items.items[self.synced..]) |e| {
            buf.clearRetainingCapacity();
            try buf.appendSlice(self.alloc, e);
            try buf.append(self.alloc, '\n');
            try sys.writeAll(fd, buf.items);
        }
        self.synced = self.items.items.len;
    }

    fn lastEquals(self: *const History, entry: []const u8) bool {
        const n = self.items.items.len;
        return n > 0 and std.mem.eql(u8, self.items.items[n - 1], entry);
    }
};

fn historyOps(alloc: std.mem.Allocator) !void {
    var h = History.init(alloc, 2);
    defer h.deinit();
    try h.add("one");
    try h.add("two");
    try h.add("three"); // evicts "one"
    _ = h.searchBack("t", h.len());
    h.setMax(1); // evicts "two"
}

test "allocation failures leave no leaks behind" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, historyOps, .{});
}

test "dedup and cap" {
    var h = History.init(std.testing.allocator, 2);
    defer h.deinit();
    try h.add("one");
    try h.add("one"); // duplicate ignored
    try h.add("two");
    try h.add("three"); // evicts "one"
    try std.testing.expectEqual(@as(usize, 2), h.len());
    try std.testing.expectEqualStrings("two", h.at(0));
    try std.testing.expectEqualStrings("three", h.at(1));
}

test "reverse search" {
    var h = History.init(std.testing.allocator, 10);
    defer h.deinit();
    try h.add("git status");
    try h.add("ls");
    try h.add("git commit");
    try std.testing.expectEqual(@as(?usize, 2), h.searchBack("git", h.len()));
    try std.testing.expectEqual(@as(?usize, 0), h.searchBack("git", 2));
    try std.testing.expectEqual(@as(?usize, null), h.searchBack("zzz", h.len()));
}

test "load propagates real errors instead of masking them" {
    var h = History.init(std.testing.allocator, 10);
    defer h.deinit();
    try h.load(".stanza_no_such_file"); // missing file: fine, stays empty
    try std.testing.expectEqual(@as(usize, 0), h.len());
    // A directory opens but cannot be read; the error must surface.
    try std.testing.expectError(error.IsDir, h.load("."));
}

test "appendNew interleaves entries from two instances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/shared", .{tmp.sub_path});

    var a = History.init(std.testing.allocator, 100);
    defer a.deinit();
    var b = History.init(std.testing.allocator, 100);
    defer b.deinit();
    try a.add("a1");
    try a.appendNew(path);
    try b.add("b1");
    try b.appendNew(path);
    try a.add("a2");
    try a.appendNew(path); // must not rewrite a1 or clobber b1
    try a.appendNew(path); // nothing new: a no-op

    var merged = History.init(std.testing.allocator, 100);
    defer merged.deinit();
    try merged.load(path);
    try std.testing.expectEqual(@as(usize, 3), merged.len());
    try std.testing.expectEqualStrings("a1", merged.at(0));
    try std.testing.expectEqualStrings("b1", merged.at(1));
    try std.testing.expectEqualStrings("a2", merged.at(2));
}

test "setMax evicts oldest and the synced watermark follows" {
    var h = History.init(std.testing.allocator, 10);
    defer h.deinit();
    try h.add("one");
    try h.add("two");
    try h.add("three");
    h.synced = 2; // as if one+two were already persisted
    h.setMax(2); // evicts "one"
    try std.testing.expectEqual(@as(usize, 2), h.len());
    try std.testing.expectEqualStrings("two", h.at(0));
    try std.testing.expectEqual(@as(usize, 1), h.synced); // shifted with it
    h.setMax(1); // evicts "two"
    try std.testing.expectEqual(@as(usize, 0), h.synced);
}

test "save and load round-trips entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buf,
        ".zig-cache/tmp/{s}/hist",
        .{tmp.sub_path},
    );
    {
        var h = History.init(std.testing.allocator, 100);
        defer h.deinit();
        try h.add("first");
        try h.add("second");
        try h.save(path);
    }
    var loaded = History.init(std.testing.allocator, 100);
    defer loaded.deinit();
    try loaded.load(path);
    try std.testing.expectEqual(@as(usize, 2), loaded.len());
    try std.testing.expectEqualStrings("first", loaded.at(0));
    try std.testing.expectEqualStrings("second", loaded.at(1));
}
