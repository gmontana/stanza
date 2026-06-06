//! The editor: it owns the terminal, the line buffer, and history, and turns a
//! stream of decoded keys into a finished line.
//!
//! `prompt` is the whole public surface. On a real terminal it drives raw-mode
//! editing with completion, hints, highlighting, kill/yank, reverse search, and
//! bracketed paste; when no terminal is available it falls back to a plain line
//! read so pipelines keep working. The returned slice is owned by the caller.
//! History is exposed directly so the host can add, load, and save.

const std = @import("std");
const config = @import("config.zig");
const key = @import("key.zig");
const sys = @import("sys.zig");
const render = @import("render.zig");
const unicode = @import("unicode.zig");
const Terminal = sys.Terminal;
const Line = @import("line.zig").Line;
const History = @import("history.zig").History;

pub const Editor = struct {
    alloc: std.mem.Allocator,
    cfg: config.Config,
    term: Terminal,
    history: History,
    line: Line,
    src: key.Source,
    arena: std.heap.ArenaAllocator,
    out_buf: std.ArrayList(u8) = .empty,
    glyphs: std.ArrayList(render.Glyph) = .empty,
    paint_buf: std.ArrayList(u8) = .empty,
    prompt_text: []const u8 = "",
    hist_idx: ?usize = null,
    stash: ?[]u8 = null,
    vi_normal: bool = false,
    vi_count: usize = 0,
    vi_op: ?u8 = null,
    vi_replace: bool = false,
    sized: bool = false,
    ml_row: usize = 0,
    resize_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pasting: bool = false,
    paste_match: usize = 0,
    paste_buf: std.ArrayList(u8) = .empty,
    search_state: ?SearchState = null,

    const Action = enum { cont, submit, cancel, eof };
    const SearchStep = enum { stay, submit, restore, leave };
    const SearchState = struct {
        saved: []u8,
        q: std.ArrayList(u8) = .empty,
        idx: ?usize = null,
    };

    pub const Step = union(enum) { line: []u8, more };

    pub fn init(alloc: std.mem.Allocator, cfg: config.Config) Editor {
        return initTerminal(alloc, cfg, Terminal.initDefault());
    }

    pub fn initFd(
        alloc: std.mem.Allocator,
        cfg: config.Config,
        in_fd: sys.Fd,
        out_fd: sys.Fd,
    ) Editor {
        return initTerminal(alloc, cfg, Terminal.init(in_fd, out_fd));
    }
    fn initTerminal(alloc: std.mem.Allocator, cfg: config.Config, tty: Terminal) Editor {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .term = tty,
            .history = History.init(alloc, cfg.max_history),
            .line = Line.init(alloc),
            .src = .{ .fd = tty.in },
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Editor) void {
        self.term.disableRaw(); // defensive: restore the tty even if editStop was skipped
        self.term.closeOwned();
        self.clearSearch();
        self.line.deinit();
        self.history.deinit();
        self.arena.deinit();
        self.out_buf.deinit(self.alloc);
        self.glyphs.deinit(self.alloc);
        self.paint_buf.deinit(self.alloc);
        self.paste_buf.deinit(self.alloc);
        self.clearStash();
    }

    /// Read one line. Returns an owned slice the caller must free, or
    /// `error.Eof` (Ctrl-D on an empty line / closed input) or
    /// `error.Interrupted` (Ctrl-C).
    pub fn prompt(self: *Editor, text: []const u8) ![]u8 {
        if (!self.term.isTty()) return self.plainRead(text);
        try self.editStart(text);
        defer self.editStop();
        while (true) {
            switch (try self.editFeed()) {
                .line => |l| return l,
                .more => _ = self.waitInput(-1),
            }
        }
    }

    // --- event-loop API ---

    /// Begin editing: enter raw mode and draw the prompt, then return. Call
    /// `waitInput` before `editFeed`, and `editStop` when done.
    /// Requires a terminal (use `prompt` for the pipe-friendly path).
    pub fn editStart(self: *Editor, text: []const u8) !void {
        if (self.cfg.install_resize_handler) sys.installResize();
        try self.term.enableRaw();
        errdefer self.editStop(); // never leave the tty raw on a failed start
        self.term.pasteOn();
        // Query width once; later changes arrive via notifyResize or the
        // optional SIGWINCH handler.
        // Re-querying every line would read (and eat) any typed-ahead bytes.
        if (!self.sized) {
            self.term.updateSize();
            self.sized = true;
        }
        self.line.clear();
        self.resetNav();
        self.resetVi();
        self.resetPaste();
        self.clearSearch();
        self.ml_row = 0;
        if (self.cfg.editing == .vi) self.term.cursorShape(false);
        self.prompt_text = text;
        try self.redraw();
    }

    /// Process all currently-available input without blocking. Returns `.line`
    /// (owned, free it) on Enter, `.more` while the line is unfinished, or
    /// `error.Eof` / `error.Interrupted`.
    pub fn editFeed(self: *Editor) !Step {
        if (self.resize_requested.swap(false, .seq_cst) or sys.resized()) {
            self.term.updateSize();
        }
        var redraw_prompt = true;
        while (true) {
            if (self.pasting) {
                if (try self.feedPaste()) continue;
                redraw_prompt = false;
                break;
            }
            if (self.search_state != null) {
                const action = (try self.feedSearch()) orelse {
                    redraw_prompt = false;
                    break;
                };
                if (try self.stepFromAction(action)) |step| return step;
                continue;
            }
            const decoded = (try key.decode(&self.src)) orelse break;
            if (try self.stepFromAction(try self.apply(decoded))) |step| return step;
        }
        if (redraw_prompt) try self.redraw();
        return .more;
    }

    fn stepFromAction(self: *Editor, action: Action) !?Step {
        return switch (action) {
            .cont => null,
            .submit => .{ .line = try self.finish() },
            .cancel => {
                self.endLine();
                return error.Interrupted;
            },
            .eof => {
                self.endLine();
                return error.Eof;
            },
        };
    }

    /// Restore the terminal after `editStart`.
    pub fn editStop(self: *Editor) void {
        self.resetPaste();
        self.clearSearch();
        if (self.cfg.editing == .vi) self.term.cursorReset();
        self.term.pasteOff();
        self.term.disableRaw();
    }

    /// Tell the editor that the terminal size changed. This is for hosts that
    /// observe resize events themselves and leave `install_resize_handler` false.
    pub fn notifyResize(self: *Editor) void {
        self.resize_requested.store(true, .seq_cst);
    }

    /// Wait for input on the editor's descriptor. This is the portable helper
    /// for event loops that only need to sleep until editing can make progress.
    pub fn waitInput(self: *const Editor, ms: i32) bool {
        return sys.readable(self.src.fd, ms);
    }

    /// The underlying descriptor/handle for hosts with their own event loop.
    pub fn fd(self: *const Editor) sys.Fd {
        return self.src.fd;
    }

    fn apply(self: *Editor, k: key.Key) !Action {
        if (try self.startInputMode(k)) return .cont;
        if (self.cfg.editing == .vi and self.vi_normal) return self.viNormal(k);
        switch (k) {
            .char => |cp| try self.line.insert(cp),
            .submit => return .submit,
            .interrupt => return .cancel,
            .cancel => return .cancel,
            .eof => return .eof,
            .ctrl_d => if (self.line.isEmpty()) return .eof else self.line.deleteFwd(),
            .tab => try self.complete(),
            .backspace => self.line.backspace(),
            .del_fwd => self.line.deleteFwd(),
            .left => self.line.left(),
            .right => self.line.right(),
            .home => self.line.home(),
            .end => self.line.end(),
            .word_left => self.line.wordLeft(),
            .word_right => self.line.wordRight(),
            .kill_to_end => try self.line.killToEnd(),
            .kill_to_home => try self.line.killToHome(),
            .kill_word_back => try self.line.killWordBack(),
            .kill_word_fwd => try self.line.killWordFwd(),
            .yank => try self.line.yank(),
            .transpose => self.line.transpose(),
            .clear => {
                try self.term.write("\x1b[H\x1b[2J");
                self.ml_row = 0; // the cursor is home; the block redraws from row 0
            },
            .up => try self.histPrev(),
            .down => try self.histNext(),
            .search_back, .paste_begin => unreachable,
            .escape => if (self.cfg.editing == .vi) self.enterNormal(),
            .backtab, .ignore => {},
        }
        return .cont;
    }

    fn startInputMode(self: *Editor, k: key.Key) !bool {
        switch (k) {
            .search_back => {
                try self.startSearch();
                return true;
            },
            .paste_begin => {
                self.startPaste();
                return true;
            },
            else => return false,
        }
    }

    fn redraw(self: *Editor) !void {
        const args = render.DrawArgs{
            .cols = self.term.cols,
            .alloc = self.alloc,
            .out = &self.out_buf,
            .glyphs = &self.glyphs,
            .paint_buf = &self.paint_buf,
            .prompt = self.prompt_text,
            .text = self.line.text(),
            .cursor = self.line.cursor,
            .cfg = self.cfg,
        };
        if (self.cfg.multiline) {
            try render.buildMulti(args, &self.ml_row);
        } else {
            try render.build(args);
        }
        try self.term.write(self.out_buf.items);
    }

    fn finish(self: *Editor) ![]u8 {
        self.endLine();
        return self.alloc.dupe(u8, self.line.text());
    }

    fn endLine(self: *Editor) void {
        if (self.cfg.editing == .vi) self.term.cursorReset();
        self.term.write("\r\n") catch {};
        self.clearStash();
    }

    // --- history navigation ---

    fn histPrev(self: *Editor) !void {
        const n = self.history.len();
        if (n == 0) return self.term.bell();
        if (self.hist_idx) |i| {
            if (i == 0) return self.term.bell();
            self.hist_idx = i - 1;
        } else {
            self.stash = try self.alloc.dupe(u8, self.line.text());
            self.hist_idx = n - 1;
        }
        try self.line.setText(self.history.at(self.hist_idx.?));
    }

    fn histNext(self: *Editor) !void {
        const i = self.hist_idx orelse return self.term.bell();
        if (i + 1 < self.history.len()) {
            self.hist_idx = i + 1;
            try self.line.setText(self.history.at(i + 1));
        } else {
            self.hist_idx = null;
            try self.line.setText(self.stash orelse "");
            self.clearStash();
        }
    }

    fn resetNav(self: *Editor) void {
        self.hist_idx = null;
        self.clearStash();
    }

    fn clearStash(self: *Editor) void {
        if (self.stash) |s| self.alloc.free(s);
        self.stash = null;
    }

    // --- completion ---

    fn complete(self: *Editor) !void {
        const cb = self.cfg.complete orelse return self.term.bell();
        _ = self.arena.reset(.retain_capacity);
        var comps = config.Completions{ .arena = self.arena.allocator() };
        const word = self.currentWord();
        try cb(self.cfg.ctx, word, &comps);
        const items = comps.items.items;
        if (items.len == 0) return self.term.bell();
        if (items.len == 1) return self.line.replaceBack(word.len, items[0]);
        const lcp = longestPrefix(items);
        if (lcp.len > word.len) return self.line.replaceBack(word.len, lcp);
        try self.listComps(items);
    }

    fn currentWord(self: *Editor) []const u8 {
        const t = self.line.text();
        var s = self.line.cursor;
        while (s > 0 and t[s - 1] != ' ' and t[s - 1] != '\t') s -= 1;
        return t[s..self.line.cursor];
    }

    fn listComps(self: *Editor, items: []const []const u8) !void {
        try self.term.write("\r\n");
        for (items) |c| {
            try self.term.write(c);
            try self.term.write("   ");
        }
        try self.term.write("\r\n");
        // The cursor now sits on a fresh row below the listing; that row is the
        // top of the next redraw, so a stale ml_row must not pull it back up.
        self.ml_row = 0;
    }

    // --- bracketed paste ---

    fn startPaste(self: *Editor) void {
        self.resetPaste();
        self.pasting = true;
    }

    fn resetPaste(self: *Editor) void {
        self.pasting = false;
        self.paste_match = 0;
        self.paste_buf.clearRetainingCapacity();
    }

    fn feedPaste(self: *Editor) !bool {
        while (try self.src.nextAvailable()) |b| {
            if (try self.stepPaste(b)) {
                try self.finishPaste();
                return true;
            }
        }
        if (self.src.ended()) {
            try self.flushPrefix();
            try self.finishPaste();
            return true;
        }
        return false;
    }

    fn stepPaste(self: *Editor, b: u8) !bool {
        const tail = "\x1b[201~";
        if (b == tail[self.paste_match]) {
            self.paste_match += 1;
            return self.paste_match == tail.len;
        }
        try self.flushPrefix();
        if (b == tail[0]) {
            self.paste_match = 1;
        } else {
            try appendPaste(&self.paste_buf, self.alloc, b);
        }
        return false;
    }

    fn flushPrefix(self: *Editor) !void {
        const tail = "\x1b[201~";
        for (tail[0..self.paste_match]) |p| try appendPaste(&self.paste_buf, self.alloc, p);
        self.paste_match = 0;
    }

    fn finishPaste(self: *Editor) !void {
        try self.line.insertText(self.paste_buf.items);
        self.resetPaste();
    }

    // --- reverse incremental search ---

    fn startSearch(self: *Editor) !void {
        self.clearSearch();
        self.search_state = .{ .saved = try self.alloc.dupe(u8, self.line.text()) };
        if (self.ml_row > 0) {
            self.out_buf.clearRetainingCapacity();
            try render.appendNum(&self.out_buf, self.alloc, "\x1b[", self.ml_row, "A");
            try self.term.write(self.out_buf.items);
            self.ml_row = 0;
        }
        try self.drawSearch("", false);
    }

    fn feedSearch(self: *Editor) !?Action {
        while (true) {
            const k = (try key.decode(&self.src)) orelse return null;
            const state = if (self.search_state) |*state| state else return .cont;
            const step = try self.searchKey(k, &state.q, &state.idx);
            switch (step) {
                .stay => {},
                .submit => {
                    self.clearSearch();
                    try self.redraw();
                    return .submit;
                },
                .restore => {
                    const saved = self.search_state.?.saved;
                    try self.line.setText(saved);
                    self.clearSearch();
                    return .cont;
                },
                .leave => {
                    self.clearSearch();
                    return .cont;
                },
            }
            if (state.idx) |i| try self.line.setText(self.history.at(i));
            try self.drawSearch(state.q.items, state.idx == null and state.q.items.len > 0);
        }
    }

    fn clearSearch(self: *Editor) void {
        if (self.search_state) |*state| {
            self.alloc.free(state.saved);
            state.q.deinit(self.alloc);
        }
        self.search_state = null;
    }

    fn searchKey(self: *Editor, k: key.Key, q: *std.ArrayList(u8), idx: *?usize) !SearchStep {
        switch (k) {
            .char => |cp| {
                try appendCp(q, self.alloc, cp);
                idx.* = self.searchPrev(q.items, null);
            },
            .backspace => {
                popCp(q);
                idx.* = self.searchPrev(q.items, null);
            },
            .search_back => idx.* = self.searchPrev(q.items, idx.*),
            .submit => return .submit,
            .cancel, .interrupt => return .restore,
            // .eof means the input stream closed; staying would spin forever.
            .eof => return .leave,
            .ignore => {},
            else => return .leave,
        }
        return .stay;
    }

    fn searchPrev(self: *Editor, q: []const u8, from: ?usize) ?usize {
        return self.history.searchBack(q, from orelse self.history.len());
    }

    fn drawSearch(self: *Editor, q: []const u8, failed: bool) !void {
        self.out_buf.clearRetainingCapacity();
        const tag = if (failed) "(failed reverse-i-search)`" else "(reverse-i-search)`";
        try self.out_buf.appendSlice(self.alloc, "\r\x1b[J");
        try self.out_buf.appendSlice(self.alloc, tag);
        try self.out_buf.appendSlice(self.alloc, q);
        try self.out_buf.appendSlice(self.alloc, "': ");
        // Truncate the match to the row so a long line cannot autowrap and
        // desynchronize the cursor from the editor's row accounting.
        const used = tag.len + unicode.strWidth(q) + 3;
        const room = if (self.term.cols > used + 1) self.term.cols - used - 1 else 0;
        try self.out_buf.appendSlice(self.alloc, render.truncCells(self.line.text(), room));
        try self.term.write(self.out_buf.items);
    }

    // --- vi mode ---

    fn viNormal(self: *Editor, k: key.Key) !Action {
        switch (k) {
            .char => |cp| try self.viChar(cp),
            .submit => return .submit,
            .interrupt, .cancel => return .cancel,
            // .eof is a closed input stream (Ctrl-D arrives as .ctrl_d), so it
            // must always end the line or the editor spins on a dead fd.
            .eof => return .eof,
            .left, .backspace => self.line.left(),
            .right => self.line.cursor = self.viRight(self.line.cursor),
            .up => try self.histPrev(),
            .down => try self.histNext(),
            .home => self.line.home(),
            .end => self.line.end(),
            .escape => self.resetPending(),
            else => {},
        }
        return .cont;
    }

    fn viChar(self: *Editor, cp_full: u21) !void {
        if (self.vi_replace) return self.viReplace(cp_full);
        const cp: u8 = if (cp_full < 128) @intCast(cp_full) else 0;
        if ((cp >= '1' and cp <= '9') or (cp == '0' and self.vi_count > 0)) {
            self.vi_count = self.vi_count *| 10 +| (cp - '0'); // saturate, never trap
            return;
        }
        // No count exceeds the line length in effect; clamping keeps absurd
        // counts from spinning through billions of no-op motion steps.
        const raw = if (self.vi_count == 0) 1 else self.vi_count;
        const count = @min(raw, self.line.text().len + 1);
        self.vi_count = 0;
        if (self.vi_op) |op| {
            self.vi_op = null;
            return self.viOperate(op, cp, count);
        }
        return self.viCommand(cp, count);
    }

    fn viCommand(self: *Editor, cp: u8, count: usize) !void {
        switch (cp) {
            'i' => self.enterInsert(),
            'a' => self.appendInsert(),
            'I' => {
                self.line.home();
                self.enterInsert();
            },
            'A' => {
                self.line.end();
                self.enterInsert();
            },
            's' => {
                self.line.deleteFwd();
                self.enterInsert();
            },
            'x' => try self.viDelChars(count),
            'D' => try self.line.killToEnd(),
            'C' => {
                try self.line.killToEnd();
                self.enterInsert();
            },
            'p' => try self.line.yank(), // pastes at the cursor (vi puts it after)
            '~' => self.line.swapCase(),
            'r' => self.vi_replace = true, // replaces one char; a count is ignored
            'd', 'c' => self.vi_op = cp,
            else => self.viMove(cp, count),
        }
    }

    fn appendInsert(self: *Editor) void {
        self.line.right();
        self.enterInsert();
    }

    fn viMove(self: *Editor, cp: u8, count: usize) void {
        if (self.viMotion(cp, count)) |idx| self.line.cursor = idx else self.term.bell();
    }

    fn viMotion(self: *Editor, cp: u8, count: usize) ?usize {
        var idx = self.line.cursor;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            idx = switch (cp) {
                'h' => self.line.idxLeft(idx),
                'l', ' ' => self.viRight(idx),
                'w' => self.line.idxWordFwd(idx),
                'e' => self.line.idxWordR(idx),
                'b' => self.line.idxWordL(idx),
                '0', '^' => 0,
                '$' => self.viLineEnd(),
                else => return null,
            };
        }
        return idx;
    }

    fn viRight(self: *Editor, idx: usize) usize {
        const len = self.line.text().len;
        const next = self.line.idxRight(idx);
        return if (len > 0 and next >= len) self.line.idxLeft(len) else next;
    }

    fn viLineEnd(self: *Editor) usize {
        const len = self.line.text().len;
        return if (len == 0) 0 else self.line.idxLeft(len);
    }

    fn viOperate(self: *Editor, op: u8, cp: u8, count: usize) !void {
        if (cp == op) { // dd / cc
            try self.line.deleteSpan(0, self.line.text().len);
            if (op == 'c') self.enterInsert();
            return;
        }
        // `cw` deliberately acts like `dw` (the gap goes too), unlike vi's `ce`.
        const target = if (cp == '$')
            self.line.text().len
        else
            self.viMotion(cp, count) orelse return self.term.bell();
        const lo = @min(self.line.cursor, target);
        const hi = @max(self.line.cursor, target);
        try self.line.deleteSpan(lo, hi);
        if (op == 'c') self.enterInsert();
    }

    fn viDelChars(self: *Editor, count: usize) !void {
        const start = self.line.cursor;
        var stop = start;
        var i: usize = 0;
        while (i < count and stop < self.line.text().len) : (i += 1) {
            stop = self.line.idxRight(stop);
        }
        if (stop > start) try self.line.deleteSpan(start, stop);
    }

    fn viReplace(self: *Editor, cp: u21) !void {
        self.vi_replace = false;
        if (self.line.cursor >= self.line.text().len) return self.term.bell();
        self.line.deleteFwd();
        try self.line.insert(cp);
        self.line.left();
    }

    fn enterInsert(self: *Editor) void {
        self.vi_normal = false;
        self.term.cursorShape(false);
    }

    fn enterNormal(self: *Editor) void {
        self.vi_normal = true;
        if (self.line.cursor > 0) self.line.left();
        self.resetPending();
        self.term.cursorShape(true);
    }

    fn resetPending(self: *Editor) void {
        self.vi_count = 0;
        self.vi_op = null;
        self.vi_replace = false;
    }

    fn resetVi(self: *Editor) void {
        self.vi_normal = false;
        self.resetPending();
    }

    // --- non-tty fallback ---

    fn plainRead(self: *Editor, text: []const u8) ![]u8 {
        if (sys.isTty(self.term.out)) try self.term.write(text);
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.alloc);
        var got = false;
        var pending_cr = false; // strip a CR only when it terminates the line
        while (try self.src.next()) |b| {
            got = true;
            if (b == '\n') return buf.toOwnedSlice(self.alloc);
            if (pending_cr) {
                try buf.append(self.alloc, '\r');
                pending_cr = false;
            }
            if (b == '\r') {
                pending_cr = true;
                continue;
            }
            try buf.append(self.alloc, b);
        }
        if (!got) return error.Eof;
        if (pending_cr) try buf.append(self.alloc, '\r');
        return buf.toOwnedSlice(self.alloc);
    }
};

fn longestPrefix(items: []const []const u8) []const u8 {
    var p = items[0];
    for (items[1..]) |s| {
        var i: usize = 0;
        while (i < p.len and i < s.len and p[i] == s[i]) i += 1;
        p = p[0..utf8Boundary(p, i)];
    }
    return p;
}

fn utf8Boundary(s: []const u8, n: usize) usize {
    var end = n;
    while (end > 0 and end < s.len and unicode.isCont(s[end])) end -= 1;
    return end;
}

fn appendPaste(out: *std.ArrayList(u8), alloc: std.mem.Allocator, b: u8) !void {
    if (b == '\r' or b == '\n') {
        try out.append(alloc, ' ');
    } else if ((b >= 0x20 and b != 0x7f) or b == '\t') {
        try out.append(alloc, b);
    }
}

fn appendCp(q: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try q.appendSlice(alloc, buf[0..n]);
}

fn popCp(q: *std.ArrayList(u8)) void {
    if (q.items.len == 0) return;
    var j = q.items.len - 1;
    while (j > 0 and unicode.isCont(q.items[j])) j -= 1;
    q.items.len = j;
}

test "longest common prefix" {
    const items = [_][]const u8{ "commit", "config", "checkout" };
    try std.testing.expectEqualStrings("c", longestPrefix(&items));
    const two = [_][]const u8{ "config", "configure" };
    try std.testing.expectEqualStrings("config", longestPrefix(&two));
    const same_codepoint = [_][]const u8{ "éclair", "éon" };
    try std.testing.expectEqualStrings("é", longestPrefix(&same_codepoint));
    const split_codepoint = [_][]const u8{ "éclair", "êwork" };
    try std.testing.expectEqualStrings("", longestPrefix(&split_codepoint));
}

fn openWrite(path: []const u8) !sys.Fd {
    return sys.openWriteTrunc(path, 0o600);
}

fn openRead(path: []const u8) !sys.Fd {
    return sys.openRead(path);
}

fn tmpPath(buf: []u8, tmp: *std.testing.TmpDir, name: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

fn testEditor(editing: config.Editing, fd_out: sys.Fd) Editor {
    return Editor.initFd(std.testing.allocator, .{ .editing = editing }, fd_out, fd_out);
}

fn typeText(ed: *Editor, s: []const u8) !void {
    for (s) |c| _ = try ed.apply(.{ .char = c });
}

fn sendCmd(ed: *Editor, c: u8) !void {
    _ = try ed.apply(.{ .char = c });
}

test "vi: x deletes, 0/D kill to end" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "hello");
    _ = try ed.apply(.escape); // normal mode, cursor on 'o'
    try sendCmd(&ed, 'x'); // delete 'o'
    try std.testing.expectEqualStrings("hell", ed.line.text());
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'D');
    try std.testing.expectEqualStrings("", ed.line.text());
}

test "vi: dd clears, dw deletes a word" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "foo bar");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'd');
    try sendCmd(&ed, 'w');
    try std.testing.expectEqualStrings("bar", ed.line.text());
    try sendCmd(&ed, 'd');
    try sendCmd(&ed, 'd');
    try std.testing.expectEqualStrings("", ed.line.text());
}

test "vi: I/A inserts, count repeats delete" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "bcd");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, 'I'); // insert at home
    try typeText(&ed, "a"); // -> abcd
    _ = try ed.apply(.escape);
    try sendCmd(&ed, 'A'); // append at end
    try typeText(&ed, "e"); // -> abcde
    try std.testing.expectEqualStrings("abcde", ed.line.text());
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '0');
    try sendCmd(&ed, '2');
    try sendCmd(&ed, 'x'); // delete two from start
    try std.testing.expectEqualStrings("cde", ed.line.text());
}

test "vi: r replaces and ~ toggles case" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "cat");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'r');
    try sendCmd(&ed, 'b'); // c -> b
    try std.testing.expectEqualStrings("bat", ed.line.text());
    try sendCmd(&ed, '~'); // b -> B
    try std.testing.expectEqualStrings("Bat", ed.line.text());
}

test "emacs: kill/yank/word/transpose wiring" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.emacs, dn);
    defer ed.deinit();
    try typeText(&ed, "hello world");
    _ = try ed.apply(.kill_word_back);
    try std.testing.expectEqualStrings("hello ", ed.line.text());
    _ = try ed.apply(.yank);
    try std.testing.expectEqualStrings("hello world", ed.line.text());
    _ = try ed.apply(.home);
    _ = try ed.apply(.word_right);
    _ = try ed.apply(.kill_to_end);
    try std.testing.expectEqualStrings("hello", ed.line.text());
    _ = try ed.apply(.home);
    _ = try ed.apply(.right); // cursor between 'h' and 'e'
    _ = try ed.apply(.transpose);
    try std.testing.expectEqualStrings("ehllo", ed.line.text());
}

test "bracketed paste inserts sanitized text" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.emacs, dn);
    defer ed.deinit();
    // Pre-fill the input source with a paste body + end marker; newlines become
    // spaces, tabs survive, the marker is consumed.
    const body = "a\nb\tc\x1b[201~";
    @memcpy(ed.src.buf[0..body.len], body);
    ed.src.len = body.len;
    ed.startPaste();
    try std.testing.expect(try ed.feedPaste());
    try std.testing.expectEqualStrings("a b\tc", ed.line.text());
}

test "paste strips ESC bytes and still finds an end marker right after one" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.emacs, dn);
    defer ed.deinit();
    // The lone ESCs are content: they must not reach the line raw, and the
    // second one must not eat the real end marker that follows it.
    const body = "x\x1by\x1b\x1b[201~";
    @memcpy(ed.src.buf[0..body.len], body);
    ed.src.len = body.len;
    ed.startPaste();
    try std.testing.expect(try ed.feedPaste());
    try std.testing.expectEqualStrings("xy", ed.line.text());
}

test "unterminated paste keeps the held-back marker prefix as sanitized text" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.emacs, dn);
    defer ed.deinit();
    // Input ends (read returns 0 on /dev/null) mid-marker: the partial match
    // was content, sanitized like the rest (the ESC is dropped).
    const body = "ab\x1b[20";
    @memcpy(ed.src.buf[0..body.len], body);
    ed.src.len = body.len;
    ed.src.eof = true;
    ed.startPaste();
    try std.testing.expect(try ed.feedPaste());
    try std.testing.expectEqualStrings("ab[20", ed.line.text());
}

test "editFeed returns during an incomplete paste" {
    const out = try sys.devNull();
    defer sys.close(out);
    var ed = Editor.initFd(std.testing.allocator, .{ .editing = .emacs }, sys.invalid, out);
    defer ed.deinit();

    const first = "\x1b[200~abc";
    @memcpy(ed.src.buf[0..first.len], first);
    ed.src.len = first.len;
    switch (try ed.editFeed()) {
        .more => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(ed.pasting);
    try std.testing.expectEqualStrings("", ed.line.text());

    const tail = "\x1b[201~";
    @memcpy(ed.src.buf[0..tail.len], tail);
    ed.src.len = tail.len;
    ed.src.pos = 0;
    switch (try ed.editFeed()) {
        .more => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!ed.pasting);
    try std.testing.expectEqualStrings("abc", ed.line.text());
}

test "history up/down navigates and restores the draft" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.emacs, dn);
    defer ed.deinit();
    try ed.history.add("one");
    try ed.history.add("two");
    try typeText(&ed, "draft");
    _ = try ed.apply(.up);
    try std.testing.expectEqualStrings("two", ed.line.text());
    _ = try ed.apply(.up);
    try std.testing.expectEqualStrings("one", ed.line.text());
    _ = try ed.apply(.down);
    try std.testing.expectEqualStrings("two", ed.line.text());
    _ = try ed.apply(.down); // back to the in-progress draft
    try std.testing.expectEqualStrings("draft", ed.line.text());
}

test "non-tty input falls back to a plain line read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "input");
    {
        const w = try openWrite(path);
        defer sys.close(w);
        try sys.writeAll(w, "hello\nworld\n");
    }
    const in = try openRead(path);
    defer sys.close(in);
    const out = try sys.devNull();
    defer sys.close(out);
    var ed = Editor.initFd(std.testing.allocator, .{}, in, out);
    defer ed.deinit();
    const l1 = try ed.prompt("> ");
    defer std.testing.allocator.free(l1);
    try std.testing.expectEqualStrings("hello", l1);
    const l2 = try ed.prompt("> ");
    defer std.testing.allocator.free(l2);
    try std.testing.expectEqualStrings("world", l2);
    try std.testing.expectError(error.Eof, ed.prompt("> "));
}

test "vi: h/l/w/b/$/0 motions move the cursor" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "ab cd");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '0');
    try std.testing.expectEqual(@as(usize, 0), ed.line.cursor);
    try sendCmd(&ed, 'l');
    try std.testing.expectEqual(@as(usize, 1), ed.line.cursor);
    try sendCmd(&ed, 'w'); // start of next word
    try std.testing.expectEqual(@as(usize, 3), ed.line.cursor);
    try sendCmd(&ed, 'b'); // back a word
    try std.testing.expectEqual(@as(usize, 0), ed.line.cursor);
    try sendCmd(&ed, '$'); // end
    try std.testing.expectEqual(@as(usize, 4), ed.line.cursor);
}

test "vi: dollar lands on last char while d$ deletes through end" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "abcd");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '$');
    try std.testing.expectEqual(@as(usize, 3), ed.line.cursor);
    try sendCmd(&ed, 'x');
    try std.testing.expectEqualStrings("abc", ed.line.text());

    try ed.line.setText("abcd");
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'd');
    try sendCmd(&ed, '$');
    try std.testing.expectEqualStrings("", ed.line.text());
}

test "vi: a appends, p pastes the last kill" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "ac");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '0'); // on 'a'
    try sendCmd(&ed, 'a'); // append after 'a'
    try typeText(&ed, "b");
    _ = try ed.apply(.escape);
    try std.testing.expectEqualStrings("abc", ed.line.text());
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'D'); // kill "abc"
    try std.testing.expectEqualStrings("", ed.line.text());
    try sendCmd(&ed, 'p'); // paste it back
    try std.testing.expectEqualStrings("abc", ed.line.text());
}

test "vi: dd and x update the paste register" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "abc");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, 'd');
    try sendCmd(&ed, 'd');
    try std.testing.expectEqualStrings("", ed.line.text());
    try sendCmd(&ed, 'p');
    try std.testing.expectEqualStrings("abc", ed.line.text());

    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'x');
    try std.testing.expectEqualStrings("bc", ed.line.text());
    try sendCmd(&ed, 'p');
    try std.testing.expectEqualStrings("abc", ed.line.text());
}

fn twoCompletions(_: ?*anyopaque, word: []const u8, out: *config.Completions) anyerror!void {
    _ = word;
    try out.add("commit");
    try out.add("commute");
}

test "completion inserts the longest common prefix" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = Editor.initFd(std.testing.allocator, .{ .complete = twoCompletions }, dn, dn);
    defer ed.deinit();
    try typeText(&ed, "com");
    _ = try ed.apply(.tab);
    try std.testing.expectEqualStrings("comm", ed.line.text()); // common prefix of commit/commute
}

test "vi: cw changes a word, cc changes the whole line" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "foo bar");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'c'); // operator
    try sendCmd(&ed, 'w'); // ...over a word: deletes "foo " and enters insert
    try typeText(&ed, "baz");
    _ = try ed.apply(.escape);
    try std.testing.expectEqualStrings("bazbar", ed.line.text());
    try sendCmd(&ed, 'c');
    try sendCmd(&ed, 'c'); // change the whole line
    try typeText(&ed, "new");
    _ = try ed.apply(.escape);
    try std.testing.expectEqualStrings("new", ed.line.text());
}

test "vi: s substitutes a char, C changes to end of line" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "cat");
    _ = try ed.apply(.escape);
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 's'); // delete char, enter insert
    try typeText(&ed, "b"); // -> "bat"
    _ = try ed.apply(.escape);
    try std.testing.expectEqualStrings("bat", ed.line.text());
    try sendCmd(&ed, '0');
    try sendCmd(&ed, 'l'); // on 'a'
    try sendCmd(&ed, 'C'); // change to end: kills "at"
    try typeText(&ed, "ig"); // -> "big"
    _ = try ed.apply(.escape);
    try std.testing.expectEqualStrings("big", ed.line.text());
}

fn forkCompletions(_: ?*anyopaque, word: []const u8, out: *config.Completions) anyerror!void {
    _ = word;
    try out.add("commit");
    try out.add("config"); // share only "co" with the word -> no prefix to add -> list
}

test "vi: closed input reports EOF even with text on the line" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "abc");
    _ = try ed.apply(.escape);
    // .eof is a closed stream, not Ctrl-D; swallowing it would busy-spin.
    try std.testing.expect((try ed.apply(.eof)) == .eof);
}

test "search leaves on EOF instead of spinning" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.emacs, dn);
    defer ed.deinit();
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(std.testing.allocator);
    var idx: ?usize = null;
    try std.testing.expect((try ed.searchKey(.eof, &q, &idx)) == .leave);
}

test "editFeed returns during reverse search" {
    const out = try sys.devNull();
    defer sys.close(out);
    var ed = Editor.initFd(std.testing.allocator, .{ .editing = .emacs }, sys.invalid, out);
    defer ed.deinit();
    try ed.history.add("commit");

    ed.src.buf[0] = 0x12; // Ctrl-R
    ed.src.len = 1;
    switch (try ed.editFeed()) {
        .more => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(ed.search_state != null);

    const query = "co\r";
    @memcpy(ed.src.buf[0..query.len], query);
    ed.src.len = query.len;
    ed.src.pos = 0;
    switch (try ed.editFeed()) {
        .line => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("commit", line);
        },
        .more => return error.TestUnexpectedResult,
    }
    try std.testing.expect(ed.search_state == null);
}

test "vi: absurd counts neither overflow nor hang" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = testEditor(.vi, dn);
    defer ed.deinit();
    try typeText(&ed, "ab");
    _ = try ed.apply(.escape);
    // Way past usize overflow if accumulated unchecked; must stay safe...
    for (0..25) |_| try sendCmd(&ed, '9');
    try sendCmd(&ed, 'l'); // ...and the motion must return promptly, clamped
    try std.testing.expectEqual(@as(usize, 1), ed.line.cursor);
}

test "plain read strips only the line-ending CR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "cr");
    {
        const w = try openWrite(path);
        defer sys.close(w);
        try sys.writeAll(w, "a\rb\nc\r\n");
    }
    const in = try openRead(path);
    defer sys.close(in);
    const out = try sys.devNull();
    defer sys.close(out);
    var ed = Editor.initFd(std.testing.allocator, .{}, in, out);
    defer ed.deinit();
    const l1 = try ed.prompt("> ");
    defer std.testing.allocator.free(l1);
    try std.testing.expectEqualStrings("a\rb", l1); // interior CR survives
    const l2 = try ed.prompt("> ");
    defer std.testing.allocator.free(l2);
    try std.testing.expectEqualStrings("c", l2); // CRLF ending stripped
}

test "multiline: listing completions and Ctrl-L reset the block row" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    const cfg = config.Config{ .complete = forkCompletions, .multiline = true };
    var ed = Editor.initFd(std.testing.allocator, cfg, dn, dn);
    defer ed.deinit();
    try typeText(&ed, "co");
    ed.ml_row = 3; // pretend the cursor sat on row 3 of a wrapped block
    _ = try ed.apply(.tab); // lists candidates below the block
    try std.testing.expectEqual(@as(usize, 0), ed.ml_row);
    ed.ml_row = 3;
    _ = try ed.apply(.clear); // Ctrl-L homes the cursor
    try std.testing.expectEqual(@as(usize, 0), ed.ml_row);
}

test "search display truncates the match to the terminal width" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "search");
    const out = try openWrite(path);
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = Editor.initFd(std.testing.allocator, .{}, dn, out);
    defer ed.deinit();
    ed.term.cols = 30; // tag (19) + query (2) + "': " (3) leave 5 cells
    try ed.line.setText("abcdefghijklmnop");
    try ed.drawSearch("ab", false);
    sys.close(out); // flush before reading back
    const rfd = try openRead(path);
    defer sys.close(rfd);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try sys.readToEnd(rfd, std.testing.allocator, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "abcde") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "abcdef") == null);
}

test "completion lists candidates when there is nothing more to insert" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "comp");
    const out = try openWrite(path);
    const dn = try sys.devNull();
    defer sys.close(dn);
    var ed = Editor.initFd(std.testing.allocator, .{ .complete = forkCompletions }, dn, out);
    defer ed.deinit();
    try typeText(&ed, "co");
    _ = try ed.apply(.tab); // common prefix is just "co" -> lists candidates
    sys.close(out); // flush before reading back
    const rfd = try openRead(path);
    defer sys.close(rfd);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try sys.readToEnd(rfd, std.testing.allocator, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "config") != null);
}
