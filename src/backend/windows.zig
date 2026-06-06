//! Windows console and file-handle backend.

const std = @import("std");
const windows = std.os.windows;

pub const Fd = windows.HANDLE;
pub const invalid: Fd = windows.INVALID_HANDLE_VALUE;
pub const WriteError = error{WriteFailed};

const DWORD = windows.DWORD;
const UINT = windows.UINT;
const WORD = windows.WORD;
const SHORT = windows.SHORT;
const BOOL = windows.BOOL;

// SAFETY: the Win32 STD_*_HANDLE constants are documented as (DWORD)-10/-11;
// the bit pattern is the API contract, not arithmetic.
const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const CP_UTF8: UINT = 65001;

const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
const ENABLE_LINE_INPUT: DWORD = 0x0002;
const ENABLE_ECHO_INPUT: DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
const ENABLE_WRAP_AT_EOL_OUTPUT: DWORD = 0x0002;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

const WAIT_OBJECT_0: DWORD = 0x00000000;
const INFINITE: DWORD = 0xffffffff;
const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 0x00000001;
const FILE_SHARE_WRITE: DWORD = 0x00000002;
const OPEN_EXISTING: DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;

const KEY_EVENT: WORD = 0x0001;

// Virtual-key codes for keys that change state but produce no input bytes.
const VK_SHIFT: WORD = 0x10;
const VK_CONTROL: WORD = 0x11;
const VK_MENU: WORD = 0x12;
const VK_CAPITAL: WORD = 0x14;
const VK_LWIN: WORD = 0x5b;
const VK_RWIN: WORD = 0x5c;
const VK_NUMLOCK: WORD = 0x90;
const VK_SCROLL: WORD = 0x91;

const COORD = extern struct {
    X: SHORT,
    Y: SHORT,
};

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: extern union {
        UnicodeChar: u16,
        AsciiChar: u8,
    },
    dwControlKeyState: DWORD,
};

const INPUT_RECORD = extern struct {
    EventType: WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        raw: [16]u8, // mouse/focus/menu/resize arms, all <= 16 bytes
    },
};

const SMALL_RECT = extern struct {
    Left: SHORT,
    Top: SHORT,
    Right: SHORT,
    Bottom: SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?Fd;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: Fd, lpMode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: Fd, dwMode: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: Fd,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(
    hFile: Fd,
    lpBuffer: *anyopaque,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(
    hFile: Fd,
    lpBuffer: *const anyopaque,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: Fd, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn PeekConsoleInputW(
    hConsoleInput: Fd,
    lpBuffer: [*]INPUT_RECORD,
    nLength: DWORD,
    lpNumberOfEventsRead: *DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: Fd,
    lpBuffer: [*]INPUT_RECORD,
    nLength: DWORD,
    lpNumberOfEventsRead: *DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) UINT;
extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?Fd,
) callconv(.winapi) Fd;

pub fn stdin() Fd {
    return stdHandle(STD_INPUT_HANDLE);
}

pub fn stdout() Fd {
    return stdHandle(STD_OUTPUT_HANDLE);
}

fn stdHandle(which: DWORD) Fd {
    return GetStdHandle(which) orelse invalid;
}

pub const Terminal = struct {
    in: Fd,
    out: Fd,
    owns_in: bool = false,
    owns_out: bool = false,
    orig_in: ?DWORD = null,
    orig_out: ?DWORD = null,
    orig_cp: ?UINT = null,
    orig_out_cp: ?UINT = null,
    cols: usize = 80,

    pub fn init(in: Fd, out: Fd) Terminal {
        return .{ .in = in, .out = out };
    }

    pub fn initDefault() Terminal {
        var tty = init(stdin(), stdout());
        if (tty.isTty()) return tty;

        const con_in = openConsole("CONIN$") catch return tty;
        const con_out = openConsole("CONOUT$") catch {
            close(con_in);
            return tty;
        };
        if (!isTtyFd(con_in) or !isTtyFd(con_out)) {
            close(con_in);
            close(con_out);
            return tty;
        }

        return .{
            .in = con_in,
            .out = con_out,
            .owns_in = true,
            .owns_out = true,
        };
    }

    pub fn closeOwned(self: *Terminal) void {
        if (self.owns_in) close(self.in);
        if (self.owns_out and self.out != self.in) close(self.out);
        self.owns_in = false;
        self.owns_out = false;
    }

    pub fn isTty(self: *const Terminal) bool {
        return isTtyFd(self.in) and isTtyFd(self.out);
    }

    pub fn enableRaw(self: *Terminal) !void {
        if (self.orig_in != null) return;

        var in_mode: DWORD = 0;
        var out_mode: DWORD = 0;
        if (!GetConsoleMode(self.in, &in_mode).toBool()) return error.NotATerminal;
        if (!GetConsoleMode(self.out, &out_mode).toBool()) return error.NotATerminal;

        const raw_in =
            (in_mode & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT |
                ENABLE_WINDOW_INPUT | ENABLE_MOUSE_INPUT)) |
            ENABLE_EXTENDED_FLAGS |
            ENABLE_VIRTUAL_TERMINAL_INPUT;
        const raw_out = out_mode |
            ENABLE_PROCESSED_OUTPUT |
            ENABLE_WRAP_AT_EOL_OUTPUT |
            ENABLE_VIRTUAL_TERMINAL_PROCESSING;

        const cp = GetConsoleCP();
        const out_cp = GetConsoleOutputCP();
        _ = SetConsoleCP(CP_UTF8);
        _ = SetConsoleOutputCP(CP_UTF8);
        errdefer {
            _ = SetConsoleCP(cp);
            _ = SetConsoleOutputCP(out_cp);
        }

        if (!SetConsoleMode(self.in, raw_in).toBool()) return error.UnsupportedTerminal;
        errdefer _ = SetConsoleMode(self.in, in_mode);

        if (!SetConsoleMode(self.out, raw_out).toBool()) return error.UnsupportedTerminal;

        self.orig_in = in_mode;
        self.orig_out = out_mode;
        self.orig_cp = cp;
        self.orig_out_cp = out_cp;
    }

    pub fn disableRaw(self: *Terminal) void {
        if (self.orig_in) |mode| _ = SetConsoleMode(self.in, mode);
        if (self.orig_out) |mode| _ = SetConsoleMode(self.out, mode);
        if (self.orig_cp) |cp| _ = SetConsoleCP(cp);
        if (self.orig_out_cp) |cp| _ = SetConsoleOutputCP(cp);
        self.orig_in = null;
        self.orig_out = null;
        self.orig_cp = null;
        self.orig_out_cp = null;
    }

    pub fn write(self: *Terminal, bytes: []const u8) WriteError!void {
        try writeAll(self.out, bytes);
    }

    pub fn bell(self: *Terminal) void {
        self.write("\x07") catch {};
    }

    pub fn pasteOn(self: *Terminal) void {
        self.write("\x1b[?2004h") catch {};
    }

    pub fn pasteOff(self: *Terminal) void {
        self.write("\x1b[?2004l") catch {};
    }

    pub fn cursorShape(self: *Terminal, block: bool) void {
        self.write(if (block) "\x1b[2 q" else "\x1b[6 q") catch {};
    }

    pub fn cursorReset(self: *Terminal) void {
        self.write("\x1b[0 q") catch {};
    }

    pub fn updateSize(self: *Terminal) void {
        // SAFETY: GetConsoleScreenBufferInfo fills the struct before use.
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!GetConsoleScreenBufferInfo(self.out, &info).toBool()) {
            self.cols = 80;
            return;
        }
        const width = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
        self.cols = if (width > 0) @intCast(width) else 80;
    }
};

pub fn read(fd: Fd, out: []u8) !usize {
    if (out.len == 0) return 0;
    if (fd == invalid) return error.InvalidHandle;
    var got: DWORD = 0;
    const want: DWORD = @intCast(@min(out.len, std.math.maxInt(DWORD)));
    // SAFETY: ReadFile takes an untyped buffer; out.ptr is valid for `want`
    // bytes (clamped to out.len above).
    if (ReadFile(fd, @ptrCast(out.ptr), want, &got, null).toBool()) return got;
    return switch (windows.GetLastError()) {
        .BROKEN_PIPE, .HANDLE_EOF, .NO_DATA => 0,
        .INVALID_HANDLE => error.InvalidHandle,
        .ACCESS_DENIED => error.AccessDenied,
        .OPERATION_ABORTED => error.Interrupted,
        else => error.InputOutput,
    };
}

pub fn writeAll(fd: Fd, bytes: []const u8) WriteError!void {
    var done: usize = 0;
    while (done < bytes.len) {
        if (fd == invalid) return error.WriteFailed;
        const chunk_len = @min(bytes.len - done, std.math.maxInt(DWORD));
        var wrote: DWORD = 0;
        if (!WriteFile(
            fd,
            // SAFETY: WriteFile takes an untyped buffer valid for `chunk_len` bytes.
            @ptrCast(bytes[done..].ptr),
            @intCast(chunk_len),
            &wrote,
            null,
        ).toBool()) return error.WriteFailed;
        if (wrote == 0) return error.WriteFailed;
        done += wrote;
    }
}

pub fn readToEnd(fd: Fd, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try read(fd, &chunk);
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..n]);
    }
}

pub fn close(fd: Fd) void {
    if (fd != invalid) windows.CloseHandle(fd);
}

pub fn readable(fd: Fd, ms: i32) bool {
    if (fd == invalid) return false;
    var mode: DWORD = 0;
    if (!GetConsoleMode(fd, &mode).toBool()) {
        // Pipes/files: the handle is signaled exactly when a read can proceed.
        const timeout: DWORD = if (ms < 0) INFINITE else @intCast(ms);
        return WaitForSingleObject(fd, timeout) == WAIT_OBJECT_0;
    }
    return consoleReadable(fd, ms);
}

/// A console input handle is signaled by ANY pending record — including key
/// releases and bare modifier presses that translate to no bytes, which
/// would make the next ReadFile block. Peek the queue and discard inert
/// records until a byte-producing key press (or the deadline) arrives.
fn consoleReadable(fd: Fd, ms: i32) bool {
    const deadline: ?u64 = if (ms < 0) null else GetTickCount64() + @as(u64, @intCast(ms));
    // The first wait always runs, so a zero timeout still polls the handle.
    var remaining: DWORD = if (ms < 0) INFINITE else @intCast(ms);
    while (true) {
        if (WaitForSingleObject(fd, remaining) != WAIT_OBJECT_0) return false;
        // SAFETY: PeekConsoleInputW fills `got` records before any are read.
        var recs: [16]INPUT_RECORD = undefined;
        var got: DWORD = 0;
        if (!PeekConsoleInputW(fd, &recs, recs.len, &got).toBool()) return true;
        // Signaled with no records: VT-translated bytes are waiting in the
        // console's byte buffer (ConPTY feeds input that way), which the
        // record queue cannot see. ReadFile will not block.
        if (got == 0) return true;
        for (recs[0..got]) |r| {
            if (producesBytes(r)) return true;
        }
        // Only inert records at the head of the queue: consume exactly the
        // ones we inspected (records are FIFO) and wait again.
        var drained: DWORD = 0;
        if (!ReadConsoleInputW(fd, &recs, got, &drained).toBool()) return true;
        remaining = if (deadline) |d| blk: {
            const now = GetTickCount64();
            if (now >= d) return false; // budget spent draining inert records
            break :blk @intCast(@min(d - now, std.math.maxInt(DWORD) - 1));
        } else INFINITE;
    }
}

fn producesBytes(r: INPUT_RECORD) bool {
    if (r.EventType != KEY_EVENT) return false;
    const k = r.Event.KeyEvent;
    if (!k.bKeyDown.toBool()) return false;
    return switch (k.wVirtualKeyCode) {
        VK_SHIFT, VK_CONTROL, VK_MENU, VK_CAPITAL, VK_LWIN, VK_RWIN, VK_NUMLOCK, VK_SCROLL => false,
        else => true,
    };
}

pub const isTty = isTtyFd;

fn isTtyFd(fd: Fd) bool {
    if (fd == invalid) return false;
    var mode: DWORD = 0;
    return GetConsoleMode(fd, &mode).toBool();
}

pub fn openRead(path: []const u8) !Fd {
    const file = try std.Io.Dir.cwd().openFile(io(), path, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    return file.handle;
}

pub fn openWriteTrunc(path: []const u8, mode: u32) !Fd {
    _ = mode;
    const file = try std.Io.Dir.cwd().createFile(io(), path, .{
        .read = false,
        .truncate = true,
    });
    return file.handle;
}

pub fn devNull() !Fd {
    return openConsole("NUL");
}

fn openConsole(comptime name: []const u8) !Fd {
    const h = openDevice(name);
    if (h != invalid) return h;
    return switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        else => error.InputOutput,
    };
}

fn openDevice(comptime name: []const u8) Fd {
    return CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral(name),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
}

pub fn installResize() void {}

pub fn resized() bool {
    return false;
}

/// Job-control suspension does not exist on Windows; Ctrl-Z is ignored.
pub fn raiseStop() void {}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "invalid handle is not readable or a tty" {
    try std.testing.expect(!readable(invalid, 0));
    try std.testing.expect(!isTty(invalid));
}
