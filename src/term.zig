//! Terminal facade. Platform-specific terminal control lives behind
//! `backend.zig`.

const backend = @import("backend.zig");

pub const Terminal = backend.Terminal;

pub fn installResize() void {
    backend.installResize();
}

pub fn resized() bool {
    return backend.resized();
}
