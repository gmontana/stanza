//! The editor: it owns the terminal, the line buffer, and history, and turns a
//! stream of decoded keys into a finished line.
//!
//! `prompt` is the whole public surface. On a real terminal it drives raw-mode
//! editing with completion, hints, highlighting, kill/yank, reverse search, and
//! bracketed paste; when no terminal is available it falls back to a plain line
//! read so pipelines keep working. The returned slice is owned by the caller.
//! History is exposed directly so the host can add, load, and save.

const std = @import("std");
const builtin = @import("builtin");
const completion = @import("completion.zig");
const config = @import("config.zig");
const key = @import("key.zig");
const sys = @import("sys.zig");
const render = @import("render.zig");
const vi = @import("vi.zig");
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
    cycle: ?completion.CycleState = null,
    menu: ?completion.MenuState = null,
    active: bool = false,
    hidden: bool = false,

    pub const Action = enum { cont, submit, cancel, eof };
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
        // Query size once; later changes arrive via notifyResize or the
        // optional SIGWINCH handler.
        // Re-querying every line would read (and eat) any typed-ahead bytes.
        if (!self.sized) {
            self.term.updateSize();
            self.sized = true;
        }
        self.line.clear();
        self.resetNav();
        vi.reset(self);
        self.resetPaste();
        self.clearSearch();
        self.clearComps();
        self.ml_row = 0;
        self.active = true;
        self.hidden = false;
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
        self.active = false;
        self.hidden = false;
        self.resetPaste();
        self.clearSearch();
        self.clearComps();
        self.restoreTerminal();
    }

    /// Hand the terminal back without touching editor state or the
    /// allocator, so a panic handler can leave the user's shell usable:
    ///
    ///     pub const panic = std.debug.FullPanic(myPanic);
    ///     fn myPanic(msg: []const u8, ra: ?usize) noreturn {
    ///         editor.restoreTerminal();
    ///         std.debug.defaultPanic(msg, ra);
    ///     }
    pub fn restoreTerminal(self: *Editor) void {
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

    /// Erase the prompt and line so the host can print its own output above
    /// it; call `show` to repaint. Painting (including from `editFeed`) stays
    /// suppressed while hidden, though input keeps being processed. Only
    /// meaningful between `editStart` and `editStop`; safe to call twice.
    pub fn hide(self: *Editor) !void {
        if (!self.active or self.hidden) return;
        self.hidden = true;
        self.out_buf.clearRetainingCapacity();
        if (self.ml_row > 0) { // collapse a wrapped block to its top row
            try render.appendNum(&self.out_buf, self.alloc, "\x1b[", self.ml_row, "A");
            self.ml_row = 0;
        }
        try self.out_buf.appendSlice(self.alloc, "\r\x1b[J");
        try self.term.write(self.out_buf.items);
    }

    /// Repaint the prompt and line after `hide`.
    pub fn show(self: *Editor) !void {
        if (!self.active or !self.hidden) return;
        self.hidden = false;
        if (self.search_state) |*state| {
            try self.drawSearch(state.q.items, state.idx == null and state.q.items.len > 0);
        } else {
            try self.redraw();
        }
    }

    /// Print host output above the line being edited: erase the prompt,
    /// write `bytes`, repaint. When no prompt is active — or the host hid it
    /// explicitly with `hide` — the bytes are written as-is, so progress and
    /// log lines can go through one call no matter the editor's state. Rows
    /// must end in "\r\n" (raw mode does not translate bare newlines).
    pub fn printAbove(self: *Editor, bytes: []const u8) !void {
        const repaint = self.active and !self.hidden;
        if (repaint) try self.hide();
        try self.term.write(bytes);
        if (repaint) try self.show();
    }

    /// Clear the screen and repaint the prompt — what Ctrl-L does, as a
    /// public entry point for hosts that bind their own `clear` command.
    pub fn clearScreen(self: *Editor) !void {
        try self.term.write("\x1b[H\x1b[2J");
        self.ml_row = 0; // the cursor is home; the block redraws from row 0
        if (self.active and !self.hidden) try self.redraw();
    }

    fn apply(self: *Editor, k: key.Key) !Action {
        if (try self.completionKey(k)) return .cont;
        if (try self.interceptKey(k)) return .cont;
        if (self.cfg.editing == .vi and self.vi_normal) return self.viNormalKey(k);
        switch (k) {
            .char => |cp| try self.line.insert(cp),
            .submit => return .submit,
            .interrupt => return .cancel,
            .cancel => return .cancel,
            .eof => return .eof,
            .ctrl_d => if (self.line.isEmpty()) return .eof else self.line.deleteFwd(),
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
            .clear => try self.clearScreen(),
            .up => try self.histPrev(),
            .down => try self.histNext(),
            .search_back, .paste_begin, .suspend_proc => unreachable,
            .escape => if (self.cfg.editing == .vi) vi.enterNormal(self),
            .tab, .backtab => unreachable,
            .ignore => {},
        }
        return .cont;
    }

    fn completionKey(self: *Editor, k: key.Key) !bool {
        var comp = self.comps();
        switch (try completion.menuKey(&comp, k)) {
            .handled => return true,
            .pass => {},
        }
        completion.endCycleFor(&comp, k);
        // Tab is inert in vi normal mode, as it was before completion styles.
        if (self.cfg.editing == .vi and self.vi_normal) return false;
        switch (k) {
            .tab => try completion.complete(&comp),
            .backtab => try completion.back(&comp),
            else => return false,
        }
        return true;
    }

    /// Ctrl-Z: hand the terminal back, stop like a cooked-mode program
    /// would, and rebuild the editing state when the shell resumes us.
    fn suspendProc(self: *Editor) !void {
        self.editStop();
        sys.raiseStop();
        // Execution continues here after SIGCONT.
        try self.term.enableRaw();
        self.term.pasteOn();
        self.active = true;
        if (self.cfg.editing == .vi) self.term.cursorShape(self.vi_normal);
        self.term.updateSize(); // the window may have changed while stopped
        self.ml_row = 0;
        try self.redraw();
    }

    /// vi normal mode: history navigation stays an editor concern; everything
    /// else is the vi module's.
    fn viNormalKey(self: *Editor, k: key.Key) !Action {
        switch (k) {
            .up => try self.histPrev(),
            .down => try self.histNext(),
            else => return vi.normal(self, k),
        }
        return .cont;
    }

    /// Keys handled before mode dispatch: they apply in every editing mode
    /// (insert, vi normal) alike.
    fn interceptKey(self: *Editor, k: key.Key) !bool {
        switch (k) {
            .search_back => try self.startSearch(),
            .paste_begin => self.startPaste(),
            .suspend_proc => if (builtin.os.tag != .windows) try self.suspendProc(),
            else => return false,
        }
        return true;
    }

    fn redraw(self: *Editor) !void {
        if (self.hidden) return;
        var draw_cfg = self.cfg;
        if (self.menu != null) draw_cfg.hint = null;
        const args = render.DrawArgs{
            .cols = self.term.cols,
            .alloc = self.alloc,
            .out = &self.out_buf,
            .glyphs = &self.glyphs,
            .paint_buf = &self.paint_buf,
            .prompt = self.prompt_text,
            .text = self.line.text(),
            .cursor = self.line.cursor,
            .cfg = draw_cfg,
        };
        if (self.cfg.multiline) {
            try render.buildMulti(args, &self.ml_row);
        } else {
            // Menu rows go out first (they end back on the prompt's row via
            // relative moves); the prompt repaint then re-anchors the cursor.
            var comp = self.comps();
            try completion.writeMenu(&comp);
            try render.build(args);
        }
        try self.term.write(self.out_buf.items);
    }

    fn comps(self: *Editor) completion.Engine {
        return .{
            .alloc = self.alloc,
            .cfg = self.cfg,
            .term = &self.term,
            .line = &self.line,
            .arena = &self.arena,
            .out = &self.out_buf,
            .ml_row = &self.ml_row,
            .cycle = &self.cycle,
            .menu = &self.menu,
            .hidden = self.hidden,
        };
    }

    fn clearComps(self: *Editor) void {
        self.cycle = null;
        self.menu = null;
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

    // --- bracketed paste ---

    /// The end-of-paste marker the terminal sends after a bracketed paste.
    const paste_end = "\x1b[201~";

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
        if (b == paste_end[self.paste_match]) {
            self.paste_match += 1;
            return self.paste_match == paste_end.len;
        }
        try self.flushPrefix();
        if (b == paste_end[0]) {
            self.paste_match = 1;
        } else {
            try appendPaste(&self.paste_buf, self.alloc, b);
        }
        return false;
    }

    fn flushPrefix(self: *Editor) !void {
        for (paste_end[0..self.paste_match]) |p| try appendPaste(&self.paste_buf, self.alloc, p);
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
                    try self.line.setText(state.saved);
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
        if (self.hidden) return;
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

fn fuzzPaste(_: void, smith: *std.testing.Smith) !void {
    var ed = Editor.initFd(std.testing.allocator, .{}, sys.invalid, sys.invalid);
    defer ed.deinit();
    var bytes: [512]u8 = undefined;
    const n = smith.sliceWithHash(&bytes, 0);
    ed.startPaste();
    for (bytes[0..n]) |b| {
        if (try ed.stepPaste(b)) break;
    }
    try ed.flushPrefix();
    // Property: nothing unsanitized ever reaches the paste buffer — no
    // control bytes (except tab), no DEL, and ESC never survives raw.
    for (ed.paste_buf.items) |b| {
        try std.testing.expect(b == '\t' or (b >= 0x20 and b != 0x7f));
    }
}

test "fuzz: paste sanitization holds for arbitrary input" {
    try std.testing.fuzz({}, fuzzPaste, .{ .corpus = &.{
        "x\x1by\x1b\x1b[201~tail",
        "\r\n\t\x00\x7f\x1b[20",
        "\x1b[201\x1b[201~",
    } });
}

fn editorOps(alloc: std.mem.Allocator) !void {
    var ed = Editor.initFd(alloc, .{}, sys.invalid, sys.invalid);
    defer ed.deinit();
    try typeText(&ed, "hello world");
    _ = try ed.apply(.kill_word_back);
    _ = try ed.apply(.yank);
    try ed.history.add("one");
    _ = try ed.apply(.up); // stashes the draft
    _ = try ed.apply(.down); // restores it
}

test "allocation failures leave no leaks behind" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, editorOps, .{});
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

fn twoCompletions(
    _: ?*anyopaque,
    _: []const u8,
    _: usize,
    word: []const u8,
    out: *config.Completions,
) anyerror!void {
    _ = word;
    try out.add("commit");
    try out.add("commute");
}

test "vi normal mode keeps Tab inert" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    const cfg = config.Config{
        .editing = .vi,
        .complete = twoCompletions,
        .complete_style = .cycle,
    };
    var ed = Editor.initFd(std.testing.allocator, cfg, dn, dn);
    defer ed.deinit();
    try typeText(&ed, "com");
    _ = try ed.apply(.escape); // normal mode
    _ = try ed.apply(.tab);
    try std.testing.expectEqualStrings("com", ed.line.text()); // unchanged
    try std.testing.expect(ed.cycle == null and ed.menu == null);
}

test "menu rows are written before the prompt repaint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "menu");
    const out = try openWrite(path);
    const cfg = config.Config{ .complete = twoCompletions, .complete_style = .menu };
    var ed = Editor.initFd(std.testing.allocator, cfg, sys.invalid, out);
    defer ed.deinit();
    ed.active = true;
    ed.prompt_text = "> ";
    try ed.line.setText("com");
    ed.src.buf[0] = 0x09; // Tab
    ed.src.len = 1;
    switch (try ed.editFeed()) {
        .more => {},
        else => return error.TestUnexpectedResult,
    }
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    // The selected-row marker must precede the prompt repaint, and the menu
    // must return to the prompt row with a relative move, never DECSC/DECRC.
    const menu_at = try indexIn(got.items, "\x1b[7m");
    const prompt_at = try indexIn(got.items, "> commit");
    try std.testing.expect(menu_at < prompt_at);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "\x1b[s") == null);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "\x1b[2A") != null); // 2 rows
}

test "cycle completion walks candidates both ways and wraps" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    const cfg = config.Config{ .complete = twoCompletions, .complete_style = .cycle };
    var ed = Editor.initFd(std.testing.allocator, cfg, dn, dn);
    defer ed.deinit();
    try typeText(&ed, "com");
    _ = try ed.apply(.tab);
    try std.testing.expectEqualStrings("commit", ed.line.text());
    _ = try ed.apply(.tab);
    try std.testing.expectEqualStrings("commute", ed.line.text());
    _ = try ed.apply(.tab); // wraps forward
    try std.testing.expectEqualStrings("commit", ed.line.text());
    _ = try ed.apply(.backtab); // and backward
    try std.testing.expectEqualStrings("commute", ed.line.text());
}

test "any other key ends a completion cycle" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    const cfg = config.Config{ .complete = twoCompletions, .complete_style = .cycle };
    var ed = Editor.initFd(std.testing.allocator, cfg, dn, dn);
    defer ed.deinit();
    try typeText(&ed, "com");
    _ = try ed.apply(.tab);
    try std.testing.expectEqualStrings("commit", ed.line.text());
    try typeText(&ed, "x"); // ends the cycle
    try std.testing.expect(ed.cycle == null);
    _ = try ed.apply(.tab); // a fresh cycle completes the new word "commitx"
    try std.testing.expectEqualStrings("commit", ed.line.text());
}

test "intercepted keys end a completion cycle" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    const cfg = config.Config{ .complete = twoCompletions, .complete_style = .cycle };
    var ed = Editor.initFd(std.testing.allocator, cfg, sys.invalid, dn);
    defer ed.deinit();
    try typeText(&ed, "com");
    _ = try ed.apply(.tab); // -> "commit", cycle active
    try std.testing.expect(ed.cycle != null);
    // Ctrl-R rewrites the line; a kept cycle would hold stale byte counts
    // and underflow replaceBack when the new line is shorter.
    _ = try ed.apply(.search_back);
    try std.testing.expect(ed.cycle == null);
    ed.clearSearch();
}

test "a stale cycle restarts instead of slicing out of range" {
    const dn = try sys.devNull();
    defer sys.close(dn);
    const cfg = config.Config{ .complete = twoCompletions, .complete_style = .cycle };
    var ed = Editor.initFd(std.testing.allocator, cfg, dn, dn);
    defer ed.deinit();
    try typeText(&ed, "com");
    _ = try ed.apply(.tab); // -> "commit", shown_len 6
    try ed.line.setText("x"); // the line changed under the cycle
    _ = try ed.apply(.tab); // must not underflow; restarts from word "x"
    try std.testing.expectEqualStrings("commit", ed.line.text());
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

fn forkCompletions(
    _: ?*anyopaque,
    _: []const u8,
    _: usize,
    word: []const u8,
    out: *config.Completions,
) anyerror!void {
    _ = word;
    try out.add("commit");
    try out.add("config"); // share only "co" with the word -> no prefix to add -> list
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

fn readBack(alloc: std.mem.Allocator, path: []const u8, out: *std.ArrayList(u8)) !void {
    const rfd = try openRead(path);
    defer sys.close(rfd);
    try sys.readToEnd(rfd, alloc, out);
}

fn indexIn(hay: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, hay, needle) orelse error.TestUnexpectedResult;
}

test "hide erases the line, suppresses repaints, and show restores it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "hide");
    const out = try openWrite(path);
    var ed = Editor.initFd(std.testing.allocator, .{}, sys.invalid, out);
    defer ed.deinit();
    ed.active = true; // as editStart would, without needing a real tty
    ed.prompt_text = "> ";
    try ed.line.setText("abc");
    try ed.hide();
    try ed.hide(); // idempotent: must not erase twice
    try std.testing.expect(ed.hidden);
    // A key arrives while hidden: state advances, nothing is painted.
    ed.src.buf[0] = 'x';
    ed.src.len = 1;
    ed.src.pos = 0;
    switch (try ed.editFeed()) {
        .more => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("abcx", ed.line.text());
    try ed.show();
    try std.testing.expect(!ed.hidden);
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.items, "\r\x1b[J"));
    const erase_at = try indexIn(got.items, "\r\x1b[J");
    const paint_at = try indexIn(got.items, "> abcx");
    try std.testing.expect(paint_at > erase_at); // repaint only after show()
}

test "printAbove erases, prints, and repaints in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "above");
    const out = try openWrite(path);
    var ed = Editor.initFd(std.testing.allocator, .{}, sys.invalid, out);
    defer ed.deinit();
    ed.active = true; // as editStart would, without needing a real tty
    ed.prompt_text = "> ";
    try ed.line.setText("abc");
    try ed.printAbove("job done\r\n");
    try std.testing.expect(!ed.hidden); // visible again afterwards
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    const erase_at = try indexIn(got.items, "\r\x1b[J");
    const text_at = try indexIn(got.items, "job done");
    const paint_at = try indexIn(got.items, "> abc");
    try std.testing.expect(erase_at < text_at and text_at < paint_at);
}

test "printAbove passes bytes through when inactive or explicitly hidden" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "passthru");
    const out = try openWrite(path);
    var ed = Editor.initFd(std.testing.allocator, .{}, sys.invalid, out);
    defer ed.deinit();
    ed.prompt_text = "> ";
    try ed.printAbove("between prompts\r\n"); // inactive: plain write
    ed.active = true;
    try ed.hide(); // host hid the prompt itself...
    try ed.printAbove("while hidden\r\n");
    try std.testing.expect(ed.hidden); // ...printAbove must not un-hide it
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "between prompts") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "while hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "> ") == null); // never repainted
}

test "multiline hide collapses to the block top first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "mlhide");
    const out = try openWrite(path);
    var ed = Editor.initFd(std.testing.allocator, .{ .multiline = true }, sys.invalid, out);
    defer ed.deinit();
    ed.active = true;
    ed.ml_row = 2; // cursor sat on row 2 of a wrapped block
    try ed.hide();
    try std.testing.expectEqual(@as(usize, 0), ed.ml_row);
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    const up_at = try indexIn(got.items, "\x1b[2A");
    const erase_at = try indexIn(got.items, "\r\x1b[J");
    try std.testing.expect(up_at < erase_at);
}

test "clearScreen homes, clears, and repaints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "cls");
    const out = try openWrite(path);
    var ed = Editor.initFd(std.testing.allocator, .{}, sys.invalid, out);
    defer ed.deinit();
    ed.active = true;
    ed.prompt_text = "> ";
    try ed.line.setText("hi");
    ed.ml_row = 3;
    try ed.clearScreen();
    try std.testing.expectEqual(@as(usize, 0), ed.ml_row);
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    const cls_at = try indexIn(got.items, "\x1b[H\x1b[2J");
    const paint_at = try indexIn(got.items, "> hi");
    try std.testing.expect(paint_at > cls_at);
}

test "completion listing caps at max_listed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "cap");
    const out = try openWrite(path);
    const dn = try sys.devNull();
    defer sys.close(dn);
    const cfg = config.Config{ .complete = forkCompletions, .max_listed = 1 };
    var ed = Editor.initFd(std.testing.allocator, cfg, dn, out);
    defer ed.deinit();
    try typeText(&ed, "co");
    _ = try ed.apply(.tab);
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "(1 more)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "config") == null);
}

test "show repaints the search display when hidden during search" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpPath(&path_buf, &tmp, "shsearch");
    const out = try openWrite(path);
    var ed = Editor.initFd(std.testing.allocator, .{}, sys.invalid, out);
    defer ed.deinit();
    ed.active = true;
    try ed.startSearch(); // first draw
    try ed.hide();
    try ed.show(); // must repaint the search row, not the plain prompt
    sys.close(out);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    try readBack(std.testing.allocator, path, &got);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, got.items, "reverse-i-search"));
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
