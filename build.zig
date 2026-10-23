// SPDX-License-Identifier: zlib
// See FORK-LICENSE.md for what that identifier covers.

const std = @import("std");

/// Build-time helpers for runtime dispatch; share one core module per graph to preserve public type identity.
const graph = @import("runtime/graph.zig");

const manifest = @import("build.zig.zon");

const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// Package, module, and artifact name used by consumers.
const lib_name = "zlib";

const facade_source = "zig/root.zig";

/// Translation wrapper for the public zlib headers.
const translate_header = "zig/translate.h";

const test_source = "tests.zig";

const example_source = "smoke.zig";

const source_dir = "src";

/// Host program that generates target-specific zconf.h.
const zconf_generator = "tools/genzconf.c";

/// Upstream version shared by the headers, package metadata, and pkg-config.
const upstream_version: std.SemanticVersion = .{ .major = 1, .minor = 3, .patch = 2 };

/// Upstream shared-library version and soname components.
const abi_version: std.SemanticVersion = .{ .major = 1, .minor = 3, .patch = 2 };

/// Upstream OBJZ sources (src/Makefile.in:59).
const core_sources = [_][]const u8{
    "src/adler32.c",
    "src/crc32.c",
    "src/deflate.c",
    "src/infback.c",
    "src/inffast.c",
    "src/inflate.c",
    "src/inftrees.c",
    "src/trees.c",
    "src/zutil.c",
};

/// Upstream OBJG sources (src/Makefile.in:60).
const lib_sources = [_][]const u8{
    "src/compress.c",
    "src/uncompr.c",
    "src/gzclose.c",
    "src/gzlib.c",
    "src/gzread.c",
    "src/gzwrite.c",
};

/// Public upstream header; zconf.h is generated separately.
const public_headers = [_][]const u8{
    "src/zlib.h",
};

/// The configured header, installed under upstream's name beside `zlib.h`.
const generated_header = "zconf.h";

const man_pages = [_][]const u8{
    "src/zlib.3",
};

const licence_records = [_][]const u8{
    "src/LICENSE",
    "src/zlib.h",
    "src/README",
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
    "UPSTREAM.sha256",
    "FORK-NOTES.md",
    "CHANGELOG.md",
};

/// C dialect used for upstream translation units.
const c_flags = [_][]const u8{"-std=gnu99"};

/// Which `libz` the package links.
const Library = enum {
    bundled,
    system,
};

/// Cross-target matrix compiled by the default check step.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

const refused_check_targets = [_]std.Target.Query{};

fn artifactName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    public: bool,
) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// Target configuration used to generate zconf.h.
const Platform = struct {
    kind: []const u8,
    have_unistd_h: bool,
    have_stdarg_h: bool,
    dll: bool,

    /// Derives header configuration from the target, not the build host.
    fn forTarget(target: std.Build.ResolvedTarget) Platform {
        const os_tag = target.result.os.tag;
        return .{
            .kind = switch (os_tag) {
                .windows => "windows",
                .wasi => "wasi (musl)",
                .macos => "darwin",
                else => @tagName(os_tag),
            },
            .have_unistd_h = os_tag != .windows,
            .have_stdarg_h = true,
            // Match upstream's Windows DLL macros (src/win32/Makefile.gcc).
            .dll = os_tag == .windows,
        };
    }
};

/// Generates the configured zconf.h for one target.
fn addZconf(b: *std.Build, target: std.Build.ResolvedTarget, platform: Platform) std.Build.LazyPath {
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    // Compile the C generator as a source on a rootless module; a C root has no Zig root for @import("std").
    const generator_module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = true,
    });
    generator_module.addCSourceFile(.{ .file = b.path(zconf_generator) });
    const generator = b.addExecutable(.{
        .name = b.fmt("zlib-genzconf-{s}", .{triple}),
        .root_module = generator_module,
    });

    const run = b.addRunArtifact(generator);
    // genzconf expects input, output, then two probe answers (tools/genzconf.c:100).
    run.addFileArg(b.path("src/zconf.h.in"));
    const zconf = run.addOutputFileArg2(generated_header, .{});
    run.addArg(if (platform.have_unistd_h) "1" else "0");
    run.addArg(if (platform.have_stdarg_h) "1" else "0");
    return zconf;
}

/// One target's library and facade.
const Graph = struct {
    c_lib: ?*std.Build.Step.Compile,
    module: *std.Build.Module,
    platform: Platform,
    zconf: std.Build.LazyPath,
};

/// Builds the library and facade for one target.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    if (refusalFor(target.result.os.tag) != null) refuseTarget(b, target);

    const platform = Platform.forTarget(target);
    const zconf = addZconf(b, target, platform);

    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, zconf, artifactName(b, target, public))
    else
        null;

    const translate = b.addTranslateC(.{
        .root_source_file = b.path(translate_header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The generated `zconf.h` directory comes FIRST, before `src/`.
    translate.addIncludePath(zconf.dirname());
    if (library == .bundled) {
        translate.addIncludePath(b.path(source_dir));
        // zlib.h's quoted include prefers src/zconf.h; ZLIB_BUILD switches to <zconf.h>.
        translate.defineCMacro("ZLIB_BUILD", "1");
    }

    if (library == .system) {
        translate.linkSystemLibrary(lib_name, .{ .preferred_link_mode = linkage });
    }

    const module = if (public)
        b.addModule(lib_name, .{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

    graph.addHeaderImport(b, module);
    // Share one loader core per build; LoadSource and LoadError have nominal identity.
    if (runtime_loaded) {
        // Runtime mode dispatches through a provider without linking this artifact.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // Keep c private; consumers import it through the zlib facade.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // Make generated zconf.h available to dependent C sources before src/.
    module.addIncludePath(zconf.dirname());
    if (library == .bundled) module.addIncludePath(b.path(source_dir));

    return .{ .c_lib = c_lib, .module = module, .platform = platform, .zconf = zconf };
}

/// Compiles upstream's C library for one target.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    requested: std.lang.LinkMode,
    platform: Platform,
    zconf: std.Build.LazyPath,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        // Static archives have no soname or versioned filename.
        .version = if (linkage == .dynamic) abi_version else null,
        .win32_module_definition = if (linkage == .dynamic and target.result.ofmt == .coff)
            b.addWriteFiles().add("zlib.def", @embedFile("src/win32/zlib.def"))
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Shared objects require position-independent code.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    // The generated `zconf.h` directory first, then `src/`.
    c_mod.addIncludePath(zconf.dirname());
    // Source files in src/ use quoted includes for their neighbours.
    c_mod.addIncludePath(b.path(source_dir));
    // zlib.h's quoted include prefers src/zconf.h; ZLIB_BUILD switches to <zconf.h>.
    c_mod.addCMacro("ZLIB_BUILD", "1");

    // Match upstream's Windows DLL split: internal sources export and consumers import.
    // Define DLL macros only for Windows shared builds (src/win32/Makefile.gcc).
    const windows_dll = platform.dll and linkage == .dynamic;
    if (windows_dll) {
        c_mod.addCMacro("ZLIB_DLL", "1");
        c_mod.addCMacro("ZLIB_INTERNAL", "1");
    }

    for (core_sources) |source| {
        c_mod.addCSourceFile(.{
            .file = b.path(source),
            .flags = &c_flags,
        });
    }
    for (lib_sources) |source| {
        c_mod.addCSourceFile(.{
            .file = b.path(source),
            .flags = &c_flags,
        });
    }

    if (linkage == .dynamic) setVersionScript(b, c_lib, target);

    for (public_headers) |header| {
        c_lib.installHeader(b.path(header), std.Io.Dir.path.basename(header));
    }
    c_lib.installHeader(zconf, generated_header);

    return c_lib;
}

/// Applies upstream's ELF version script to shared libraries.
fn setVersionScript(
    b: *std.Build,
    c_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.ofmt != .elf) return;
    const files = b.addWriteFiles();
    c_lib.setVersionScript(files.add("zlib.map", @embedFile("src/zlib.map")));
}

/// Compiles the library, facade, tests, and example for one target without running them.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    const triple = cross_target.result.zigTriple(b.allocator) catch @panic("unspellable target");

    const cross = addGraph(b, cross_target, optimize, library, linkage, runtime_loaded, false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addTest(.{
        .name = b.fmt("zlib-tests-{s}", .{triple}),
        .root_module = test_mod,
    }).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("zlib-smoke-{s}", .{triple}),
        .root_module = example_mod,
    }).step);

    if (cross.c_lib != null) {
        step.dependOn(&cross.c_lib.?.step);
    }
}

/// Runs the consumer package as a nested build with this graph's configuration.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // Forward CPU separately; the target triple does not encode its model and features.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // Reuse this build's Zig executable for the nested build.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    run.addThirdPartyEnabledArgDarling(.{ .enabled = "-fdarling" });
    run.addThirdPartyEnabledArgQemu(.{ .enabled = "-fqemu" });
    run.addThirdPartyEnabledArgRosetta(.{ .enabled = "-frosetta" });
    run.addThirdPartyEnabledArgWasmtime(.{ .enabled = "-fwasmtime" });
    run.addThirdPartyEnabledArgWine(.{ .enabled = "-fwine" });
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // Forward caller arguments after build options, separated by --.
    run.addArg("--");
    run.addPassthruArgs();
    run.has_side_effects = true;
    return run;
}

/// Checks whether the consumer can run without configure-time executor toggles.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = .dynamic,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, candidate, options)) {
        .native, .rosetta => true,
        else => false,
    };
}

/// Writes the relocatable zlib pkg-config file.
fn add_pkg_config(
    b: *std.Build,
    platform: Platform,
    target: std.Build.ResolvedTarget,
    linkage: std.lang.LinkMode,
) void {
    const files = b.addWriteFiles();
    const windows_dll = platform.dll and deliveredLinkage(target, linkage) == .dynamic;
    // Keep the returned install step; creating it alone does not install it.
    const install_pc = b.addInstallFile(
        files.add("zlib.pc", b.fmt(
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{exec_prefix}}/lib
            \\sharedlibdir=${{libdir}}
            \\includedir=${{prefix}}/include
            \\
            \\Name: zlib
            \\Description: zlib compression library
            \\Version: {f}
            \\License: Zlib
            \\
            \\Requires:
            \\Libs: -L${{libdir}} -L${{sharedlibdir}} -lz
            \\Cflags: -I${{includedir}}{s}
            \\
        , .{
            upstream_version,
            if (windows_dll) " -DZLIB_DLL" else "",
        })),
        "lib/pkgconfig/zlib.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Installs the licence and provenance records.
fn install_licence_records(b: *std.Build) void {
    for (licence_records) |record| {
        // Keep the returned step in the install graph.
        const install_record = b.addInstallFile(
            b.path(record),
            b.fmt("share/licenses/zlib/{s}", .{std.Io.Dir.path.basename(record)}),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

/// Installs the manual page under `share/man/man3`, where upstream puts it.
fn install_man_pages(b: *std.Build) void {
    for (man_pages) |page| {
        const install_page = b.addInstallFile(
            b.path(page),
            b.fmt("share/man/man3/{s}", .{std.Io.Dir.path.basename(page)}),
        );
        b.getInstallStep().dependOn(&install_page.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_default = b.option(
        bool,
        "system",
        "Bind an installed libz instead of compiling src/, and translate the " ++
            "installed headers instead of the bundled ones. This supplies the " ++
            "default of systemIntegrationOption(\"zlib\"); a build runner that " ++
            "decides the mode itself (-fsys=zlib) overrides it.",
    ) orelse false;

    const use_system = b.systemIntegrationOption(lib_name, .{ .default = system_default });
    const library: Library = if (use_system) .system else .bundled;

    const linkage_option = b.option(
        std.lang.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default, and " ++
            "upstream's own STATICLIB at src/Makefile.in:38) or as a real " ++
            "shared object with upstream's libz.so.1.3.2 file name and " ++
            "libz.so.1 soname. This selects the delivery and never the " ++
            "dispatch: the same 15 C units are compiled either way. In system " ++
            "mode this graph builds no artifact at all, so there the option " ++
            "names the kind of installed library to bind to instead, and it " ++
            "defaults to dynamic.",
    );

    // Preserve static bundled and dynamic system defaults.
    const linkage: std.lang.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // Runtime dispatch is independent of artifact linkage.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated headers and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    ) orelse false;

    // Keep the manifest version aligned with zlib.h and pkg-config.
    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches ZLIB_VERSION in " ++
            "src/zlib.h:44; see UPSTREAM.md");
    }

    // Check both target lists against refusalFor.
    checkMatrixPartition(b);

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b, published.platform, target, linkage);
        install_licence_records(b);
        install_man_pages(b);
    }

    // Compile the example in the default install graph, but do not install it.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    const example = b.addExecutable(.{
        .name = "zlib-smoke",
        .root_module = example_mod,
    });
    b.getInstallStep().dependOn(&example.step);

    // The smoke step builds the example without depending on installation.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    run_example.addPassthruArgs();
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // Use tests.zig as the root module so Zig discovers its test blocks.
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, published.module);
    const unit_tests = b.addTest(.{
        .name = "zlib-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the behavioural tests").dependOn(&run_tests.step);

    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // Compile the library, facade, tests, and example for each check target.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests and the example for " ++
            "the six check targets without running any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, library, linkage, runtime_loaded);
    } else {
        for (check_targets[0..]) |query| {
            add_target_check(b, check_step, query, optimize, library, linkage, runtime_loaded);
        }
    }

    if (published.c_lib != null) {
        std.debug.print(
            "zlib: {d} units of OBJC (src/Makefile.in:59-61), {s}, C99 (gnu99), " ++
                "zconf.h generated for this target: HAVE_UNISTD_H={d} " ++
                "HAVE_STDARG_H={d}\n",
            .{
                core_sources.len + lib_sources.len,
                published.platform.kind,
                @intFromBool(published.platform.have_unistd_h),
                @intFromBool(published.platform.have_stdarg_h),
            },
        );
        std.debug.print("zlib: {s}\n", .{switch (deliveredLinkage(target, linkage)) {
            .static => "static archive libz.a (default, and upstream's STATICLIB)",
            .dynamic => b.fmt(
                "shared object libz.so.{d}.{d}.{d}, soname libz.so.{d}, " ++
                    "export surface from src/zlib.map (ELF) or src/win32/zlib.def (COFF)",
                .{
                    abi_version.major,
                    abi_version.minor,
                    abi_version.patch,
                    abi_version.major,
                },
            ),
        }});
        if (runtime_loaded) {
            std.debug.print(
                "zlib: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        // Non-ELF shared objects do not receive the ELF version script.
        if (deliveredLinkage(target, linkage) == .dynamic and
            target.result.ofmt != .elf)
        {
            std.debug.print(
                "zlib: {s} has no version-script mechanism here, so the shared " ++
                    "object exports zlib's internal symbols as well as its API\n",
                .{@tagName(target.result.ofmt)},
            );
        }
    } else {
        std.debug.print(
            "zlib: system libz (-lz) and the installed headers; this package " ++
                "installs nothing of its own\n",
            .{},
        );
        if (runtime_loaded) {
            std.debug.print(
                "zlib: runtime-loaded dispatch (-Druntime=true) over the installed " ++
                    "provider named by an explicit load(source)\n",
                .{},
            );
        }
    }
}

/// Returns whether the target can load shared objects.
/// Windows uses the PE loader without an interpreter path.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// Rejects shared linkage when the target has no dynamic linker.
fn deliveredLinkage(
    target: std.Build.ResolvedTarget,
    requested: std.lang.LinkMode,
) std.lang.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        // Format at runtime because the target OS tag is a runtime value.
        std.debug.panic(
            "zlib: -Dlinkage=dynamic was asked for {s}, which has no dynamic " ++
                "linker: std.Target.DynamicLinker.kind is .none for it, so it cannot " ++
                "carry a shared object at all. This build does not substitute a static " ++
                "archive for a requested shared object. Build that target with the " ++
                "default -Dlinkage=static, which is also what upstream's " ++
                "src/Makefile.in:38 STATICLIB produces there.",
            .{@tagName(target.result.os.tag)},
        );
    }
    return requested;
}

const Refusal = struct {
    summary: []const u8,
    detail: []const u8,
};

fn refusalFor(os_tag: std.Target.Os.Tag) ?Refusal {
    _ = os_tag;
    return null;
}

fn refuseTarget(b: *std.Build, target: std.Build.ResolvedTarget) noreturn {
    const refusal = refusalFor(target.result.os.tag) orelse
        @panic("build.zig internal error: refusalFor returned null for a target addGraph refused");
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    std.log.err("zlib: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    @panic("zlib: refusing a target this package has no buildable configuration for");
}

/// Checks that both target lists match refusalFor.
fn checkMatrixPartition(b: *std.Build) void {
    for (check_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (refusalFor(resolved.result.os.tag) != null) {
            @panic(b.fmt(
                "build.zig: {s} is in check_targets but this build refuses its operating system",
                .{resolved.result.zigTriple(b.allocator) catch @panic("unspellable check target")},
            ));
        }
    }
    for (refused_check_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (refusalFor(resolved.result.os.tag) == null) {
            @panic(b.fmt(
                "build.zig: {s} is in refused_check_targets but refusalFor no longer refuses it; move it to check_targets and prove it builds",
                .{resolved.result.zigTriple(b.allocator) catch @panic("unspellable check target")},
            ));
        }
    }
}
