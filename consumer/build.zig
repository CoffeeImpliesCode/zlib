// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.
//
//! Build wiring for the separate consumer package.
//! It checks that a dependent can use the published `zlib` module and artifact.
//! `run` exercises the selected target, linkage, and runtime-dispatch settings.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose linkage and runtime options so direct and parent builds use the same configuration.
    // Forwarding prevents the parent step from silently dropping either setting.
    const linkage = b.option(
        std.lang.LinkMode,
        "linkage",
        "Which delivery of libz to check. Forwarded to the dependency; it " ++
            "decides the artifact, never anything in this package.",
    ) orelse .static;
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Check the dependency's runtime-loading dispatch instead of a linked " ++
            "one. Forwarded to the dependency. A program built this way has to " ++
            "name a provider with an explicit load() before any native call, " ++
            "which is src/main.zig's business and not this file's.",
    ) orelse false;

    const dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime_loaded,
    });

    // System integration comes from the build runner's `-fsys` flags through the shared graph.
    // A local `-D` option would duplicate the dependency's system-integration path.

    // The library module owns the libc requirement; do not mask a missing declaration here.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zlib", dep.module("zlib"));

    const exe = b.addExecutable(.{
        .name = "zlib-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.has_side_effects = true;
    // Forward arguments such as `--provider` to the consumer program.
    run_exe.addPassthruArgs();
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);
}
