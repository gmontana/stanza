//! Build graph for Stanza: the importable `stanza` module, per-file unit tests,
//! the interactive demo, and a `qa` step that checks formatting.
//!
//! Entry points: `zig build` (install demo), `zig build test`, `zig build demo`,
//! `zig build qa`.

const std = @import("std");

const sources = [_][]const u8{
    "src/sys.zig",
    "src/unicode.zig",
    "src/config.zig",
    "src/key.zig",
    "src/line.zig",
    "src/history.zig",
    "src/term.zig",
    "src/render.zig",
    "src/editor.zig",
    "src/root.zig",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stanza = b.addModule("stanza", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    for (sources) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

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

    const fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "." });
    const qa_step = b.step("qa", "Check formatting");
    qa_step.dependOn(&fmt.step);
}
