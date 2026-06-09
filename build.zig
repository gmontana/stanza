//! Build graph for Stanza: the importable `stanza` module, per-file unit tests,
//! the interactive examples, and a `qa` step that checks formatting.
//!
//! Entry points: `zig build` (install demos), `zig build test`,
//! `zig build test-portable`, `zig build demo`, `zig build async`,
//! `zig build menu`, `zig build wrap`, `zig build keycodes`, `zig build qa`.

const std = @import("std");

const portable_sources = [_][]const u8{
    "src/unicode.zig",
    "src/config.zig",
    "src/line.zig",
    "src/render.zig",
};

const posix_sources = [_][]const u8{
    "src/backend/posix.zig",
    "src/backend.zig",
    "src/sys.zig",
    "src/key.zig",
    "src/history.zig",
    "src/completion.zig",
    "src/vi.zig",
    "src/editor.zig",
    "src/root.zig",
};

const windows_sources = [_][]const u8{
    "src/backend/windows.zig",
    "src/backend.zig",
    "src/sys.zig",
    "src/key.zig",
    "src/history.zig",
    "src/completion.zig",
    "src/vi.zig",
    "src/editor.zig",
    "src/root.zig",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_no_exec = b.option(bool, "test-no-exec", "Compile tests without running them") orelse false;

    const stanza = b.addModule("stanza", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    const portable_step = b.step("test-portable", "Run platform-independent unit tests");
    addTests(b, target, optimize, portable_step, &portable_sources, test_no_exec);
    test_step.dependOn(portable_step);
    const platform_sources = if (target.result.os.tag == .windows) &windows_sources else &posix_sources;
    addTests(b, target, optimize, test_step, platform_sources, test_no_exec);

    const demo = b.addExecutable(.{
        .name = "stanza-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.root_module.addImport("stanza", stanza);
    b.installArtifact(demo);

    const run = b.addRunArtifact(demo);
    run.step.dependOn(b.getInstallStep());
    const demo_step = b.step("demo", "Run the interactive demo");
    demo_step.dependOn(&run.step);

    const async_demo = b.addExecutable(.{
        .name = "stanza-async",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/async.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    async_demo.root_module.addImport("stanza", stanza);
    b.installArtifact(async_demo);
    const run_async = b.addRunArtifact(async_demo);
    const async_step = b.step("async", "Run the event-loop example");
    async_step.dependOn(&run_async.step);

    const menu = b.addExecutable(.{
        .name = "stanza-menu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/menu.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    menu.root_module.addImport("stanza", stanza);
    b.installArtifact(menu);
    const run_menu = b.addRunArtifact(menu);
    const menu_step = b.step("menu", "Run the completion-menu example");
    menu_step.dependOn(&run_menu.step);

    const wrap = b.addExecutable(.{
        .name = "stanza-wrap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/wrap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wrap.root_module.addImport("stanza", stanza);
    b.installArtifact(wrap);
    const run_wrap = b.addRunArtifact(wrap);
    const wrap_step = b.step("wrap", "Run the multi-line wrapping example");
    wrap_step.dependOn(&run_wrap.step);

    const keycodes = b.addExecutable(.{
        .name = "stanza-keycodes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/keycodes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    keycodes.root_module.addImport("stanza", stanza);
    b.installArtifact(keycodes);
    const run_keycodes = b.addRunArtifact(keycodes);
    const keycodes_step = b.step("keycodes", "Show the raw bytes each key sends");
    keycodes_step.dependOn(&run_keycodes.step);

    const fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "." });
    const qa_step = b.step("qa", "Check formatting");
    qa_step.dependOn(&fmt.step);
}

fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step: *std.Build.Step,
    sources: []const []const u8,
    no_exec: bool,
) void {
    for (sources) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        if (no_exec) {
            step.dependOn(&t.step);
        } else {
            step.dependOn(&b.addRunArtifact(t).step);
        }
    }
}
