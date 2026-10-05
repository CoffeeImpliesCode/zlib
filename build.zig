// SPDX-License-Identifier: zlib
// See FORK-LICENSE.md for what that identifier covers.
//
//! Zig 0.16 build for zlib 1.3.2.
//!
//! The library is upstream's own C, byte for byte: the fifteen root translation
//! units of `OBJC` in `src/Makefile.in:59-61`, and nothing else. Nothing is
//! downloaded, no `make`, no CMake, no `./configure` and no autotools script is
//! executed, and the default mode compiles everything from this repository
//! rather than linking an installed copy.
//!
//! Upstream reference: the official `zlib-1.3.2.tar.gz` release.
//! `src/zlib.h:2` says "version 1.3.2, February 17th, 2026", `src/zlib.h:44`
//! is `#define ZLIB_VERSION "1.3.2"`, `src/zlib.h:45` is `#define ZLIB_VERNUM
//! 0x1320`, and `src/README:3` says "zlib 1.3.2". The release digest belongs in
//! `UPSTREAM.md`; this script does not restate one.
//!
//! The core closure, as upstream lists it
//! --------------------------------------
//! `src/README:13-14` states it in prose - "The compression library itself is
//! composed of all source files in the root directory" - and `src/Makefile.in`
//! is the machine-readable statement:
//!
//!   src/Makefile.in:59   OBJZ = adler32.o crc32.o deflate.o infback.o inffast.o inflate.o inftrees.o trees.o zutil.o
//!   src/Makefile.in:60   OBJG = compress.o uncompr.o gzclose.o gzlib.o gzread.o gzwrite.o
//!   src/Makefile.in:61   OBJC = $(OBJZ) $(OBJG)
//!   src/Makefile.in:63   PIC_OBJZ = adler32.lo ... (the same nine)
//!   src/Makefile.in:64   PIC_OBJG = compress.lo ... (the same six)
//!   src/Makefile.in:65   PIC_OBJC = $(PIC_OBJZ) $(PIC_OBJG)
//!   src/Makefile.in:67-69   OBJA = / PIC_OBJA =     -- the assembly hooks, empty
//!   src/Makefile.in:71   OBJS = $(OBJC) $(OBJA)
//!   src/Makefile.in:73   PIC_OBJS = $(PIC_OBJC) $(PIC_OBJA)
//!   src/Makefile.in:129  libz.a: $(OBJS)
//!
//! `OBJS` is what `libz.a` is built from and `PIC_OBJS` is what
//! `$(SHAREDLIBV)` is built from (`src/Makefile.in:288-289`), so the closure
//! this package compiles is `OBJC` with `OBJA` empty: nine + six = fifteen
//! units. Nothing may be dropped from either half, and the split is not this
//! fork's: `OBJG` is the `gz*` file layer and `OBJZ` is everything else.
//!
//! ## No `minigzip`, and why
//!
//! `src/Makefile.in:78-80` makes `all` build `example$(EXE) minigzip$(EXE)`
//! and `src/Makefile.in:295-298` builds them from `src/test/example.c` and
//! `src/test/minigzip.c`. Neither is in `OBJC`, and `src/Makefile.in:313-338`
//! (`install-libs`) installs neither: it installs `libz.a`, `libz.so.1.3.2`,
//! `zlib.3`, `zlib.pc`, `zlib.h` and `zconf.h`, and nothing else. `minigzip` is
//! a *program* built on top of the library, not a part of it, so this package
//! does not compile it and installs no executable. Both files are kept in `src/`
//! unedited, and `src/test/example.c` is what `src/README:9-12` points at as the
//! library's usage example.
//!
//! ## The generated `zconf.h`
//!
//! This is the one place where a cross build cannot simply use the tree.
//! SOURCE-CONFIRMED: the tarball ships `src/zconf.h` byte-identical to
//! `src/zconf.h.in` (both sha256
//! `cb7c2c84211473b4699223edd363d3207b43b9578e739b5bf638f42204ea6e0f`), so the
//! header in the tree is the *unconfigured template*: `#if HAVE_UNISTD_H-0`
//! (`src/zconf.h.in:446`) and `#if HAVE_STDARG_H-0` (`:450`) are still off, and
//! `Z_HAVE_UNISTD_H` is never defined, so `src/zconf.h.in:488-490` never
//! reaches `#include <unistd.h>`.
//!
//! Upstream's answer is `src/configure:643-672`: copy the template, run two
//! probes, and apply two `sed` rewrites to the two probe lines. This build
//! reproduces exactly those rewrites in `tools/genzconf.c` and answers the two
//! probes from `std.Target` rather than from the host - a host program's
//! `#include <unistd.h>` is a fact about the machine that ran the build, not
//! about the machine the library is being compiled for. `Platform.forTarget` is
//! the only place those answers are computed.
//!
//! The generated header's directory has to be on the include line of four
//! separate things, and `src/zlib.h:33-38` is why: it includes `zconf.h` by
//! *bare name*, so whichever `zconf.h` the search finds first is the one every
//! unit of the library and the translation compile against.
//!
//!   * every C translation unit of `OBJC`,
//!   * the `zig translate-c` line over `zig/translate.h`,
//!   * the installed header pair, because `src/Makefile.in:346` installs the
//!     *generated* `zconf.h` (`cp $(SRCDIR)zlib.h zconf.h ...`) and not the
//!     template, and
//!   * the published module, so a dependent that compiles its own C against this
//!     package finds the same header the core was compiled with.
//!
//! In all four the generated directory is added *before* `src/`, so the bare
//! include resolves to the configured header and never to the template that is
//! also in the tree. `tools/genzconf.c` documents the four `sed` expressions it
//! reproduces and the digest that is the acceptance criterion for them.
//!
//! ## No mandatory compile macros on POSIX
//!
//! `src/configure` adds a `-D` for a probe that *failed* - `NO_SIZE_T`
//! (`:586`), `_LFS64_LARGEFILE=1` (`:601`), `NO_FSEEKO` (`:620`), `NO_STRERROR`
//! (`:637`) - and every one of those probes succeeds on a hosted POSIX target
//! with a `size_t`, large-file support and `strerror`. So the compile line for
//! a POSIX target here carries no `-D` at all, which is the shape the package
//! contract asks for and the shape a C consumer of `include/` gets.
//!
//! What is deliberately *not* defined, each for a reason upstream states:
//!
//!   * `ZLIB_CONST`. `src/configure:264-270` defines it only under `--const`,
//!     which is not a default. It turns `z_const` into `const`
//!     (`src/zconf.h:245-251`), which changes what the C compiler accepts for
//!     `z_stream.next_in` (`src/zlib.h:91`), `z_stream.msg` (`:99`) and
//!     `inflateBack`'s callback (`:1135`). Leaving it off is what keeps this
//!     package's headers compatible with every existing C consumer, which is
//!     what `src/zconf.h:13-14` means by "The 'standard' zlib should be
//!     compiled without it".
//!   * `Z_PREFIX`. `src/zconf.h:17-18` would rename every public symbol to
//!     `z_*` (`:26-38`), so `libz` would export `z_deflate` and no consumer
//!     could link it. `src/configure:676-681` reaches it only through
//!     `--zprefix`. `tools/genzconf.c` can reproduce the rewrite
//!     (`src/configure:677`) and this build asks for neither.
//!   * `Z_SOLO`. `src/configure:684-692` would drop `gz*` from the object lists
//!     as well as baking `#define Z_SOLO` into the header. `tools/genzconf.c`
//!     can reproduce that rewrite (`src/configure:685`) and this build asks for
//!     neither, because the `gz*` half of the API is installed.
//!   * `ZLIB_DEBUG`, `ZLIB_INSECURE`, `ZLIB_WINAPI`. All three are options -
//!     `--debug` (`src/configure:284-287`), `--insecure` (`:280-282`) and a
//!     Windows-only calling-convention switch (`src/zconf.h:353-357`, whose own
//!     comment says "the standard ZLIB1.DLL is NOT compiled using ZLIB_WINAPI").
//!   * `crc32_vx`. `src/Makefile.in:150-151` builds `contrib/crc32vx/crc32_vx.c`
//!     only when `VGFMAFLAG` is set, and `src/configure:918-935` is the only
//!     thing that sets it (s390x). The vectorised CRC is a different
//!     implementation of the same function, not part of `OBJC`, and it would
//!     need a per-target assembly selection this package does not make.
//!
//! ## Static and shared delivery
//!
//! Upstream ships both. `src/Makefile.in:38-41`:
//!
//!   src/Makefile.in:38   STATICLIB=libz.a
//!   src/Makefile.in:39   SHAREDLIB=libz.so
//!   src/Makefile.in:40   SHAREDLIBV=libz.so.1.3.2
//!   src/Makefile.in:41   SHAREDLIBM=libz.so.1
//!
//! so `-Dlinkage=static` gives `libz.a` and `-Dlinkage=dynamic` gives
//! `libz.so.1.3.2` with `libz.so` and `libz.so.1` beside it, exactly the three
//! names upstream links (`src/Makefile.in:42`). The shared object is delivered
//! with upstream's own two export surfaces: `src/zlib.map` on ELF, read as
//! bytes and handed to the linker unmodified, and `src/win32/zlib.def` on COFF.
//!
//! `-Dlinkage` decides only which artifact this build *delivers and installs*.
//! The fifteen units are compiled the same way either way, and `-Druntime` is a
//! separate question about how the Zig facade reaches them.
//!
//! Entry points
//! -----------
//!   zig build           install the library, the two public headers, the
//!                        `zlib` manual page, the `zlib.pc` pkg-config file and
//!                        the licence and provenance records
//!   zig build test      run the behavioural tests for the selected target
//!                        (`-Dtarget`; the host when it is absent)
//!   zig build smoke     run the deterministic example program
//!   zig build consumer  build the separate `consumer/` package, and run it when
//!                        this host can execute the selected target
//!   zig build check     compile the native library, the facade, the tests and
//!                        the example for the six check targets, running
//!                        nothing
//!
//! Options
//! -------
//!   -Dlinkage=static   a static archive, `libz.a` (the default; upstream's
//!                      `STATICLIB`)
//!   -Dlinkage=dynamic  `libz.so.1.3.2`, soname `libz.so.1`, with upstream's
//!                      version script and export list
//!   -Druntime=true     resolve the native entry points at run time instead of
//!                      linking them. Orthogonal to `-Dlinkage`. Default off.
//!   -Dsystem=true      bind an installed `libz` instead of compiling `src/`.
//!                      Supplies the default of
//!                      `b.systemIntegrationOption("zlib", ...)`; `-fsys=zlib`
//!                      overrides it.
//!   -Dtarget=<triple>  build for one target; `check` then checks that target
//!   -Doptimize=<mode>  the caller's mode, passed to every graph below

const std = @import("std");

/// The runtime-loading build half, owned by the API role.
///
/// `createModule` builds the generated dispatch that replaces
/// `translate.createModule()` under `-Druntime`; it makes the loader-core
/// module itself and re-exports `LoadSource`/`LoadError` from it.
/// `createCoreModule` builds that same core module for the *linked* branch,
/// where there is no dispatch to carry the types and the facade's `rt` import
/// is where they come from.
///
/// The two branches must not both call `createCoreModule`. `LoadSource` and
/// `LoadError` are this SDK's public types, so they have to be the *same* types
/// in one build: a second core instance would be a second, nominally distinct
/// `LoadSource`, and `zlib.load(source)` would be handing the facade's type to a
/// function expecting the dispatch's. `addGraph` is the only place that calls
/// either of them.
const graph = @import("runtime/graph.zig");

/// `build.zig.zon` itself. `@import` of the manifest is how a build script
/// reads `.version` without a second copy of it.
const manifest = @import("build.zig.zon");

/// `build.zig.zon .version`, parsed. The parse is the loud part: a manifest
/// whose `.version` is not a semantic version fails to configure here rather
/// than being silently compared as something else.
const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// Package id, the name a dependent writes in its dependency map, the one
/// registered module and the C artifact. They are one name on purpose:
/// `dep.module("zlib")` and `dep.artifact("zlib")` describe the same library,
/// and `libz.a` is what Zig emits for an artifact called `zlib` because
/// `std.zig.system` prepends the platform's `lib` prefix - which is also
/// upstream's own `STATICLIB` (`src/Makefile.in:38`) and the name a C
/// consumer's `-lz` resolves.
const lib_name = "zlib";

/// The Zig facade. It re-exports the translated module as `c`.
const facade_source = "zig/root.zig";

/// The one header this package translates. It is a fork-authored wrapper whose
/// whole job is to name the two public headers `src/Makefile.in:343-347`
/// installs; see the file for why it is a wrapper and not a copy.
const translate_header = "zig/translate.h";

/// Test root, owned by the API role.
const test_source = "tests.zig";

/// The deterministic example program, owned by the API role.
const example_source = "smoke.zig";

/// Where the native source lives. Every internal include in this tree is quoted
/// and relative to this directory, so one include path given to every C
/// compilation and to the translation is what keeps all of it resolvable.
const source_dir = "src";

/// The generator that produces the per-target configured `zconf.h`. It is a
/// host program for a reason: `build.zig` computes the probe answers and this
/// program rewrites, and a program that ran on the target would only be able to
/// answer for itself.
const zconf_generator = "tools/genzconf.c";

/// Upstream's version, read out of `src/zlib.h:44` (`ZLIB_VERSION "1.3.2"`)
/// and `src/zlib.h:45` (`ZLIB_VERNUM 0x1320`). It is the version of the C
/// library this package builds, and `build.zig.zon .version` carries the same
/// string; `build` refuses to configure when the two drift apart, so the
/// pkg-config `Version:` field, the shared object's file name and the package
/// manifest cannot describe three different releases.
const upstream_version: std.SemanticVersion = .{ .major = 1, .minor = 3, .patch = 2 };

/// The shared object's name and soname, from `src/Makefile.in:40-41`:
/// `SHAREDLIBV=libz.so.1.3.2` and `SHAREDLIBM=libz.so.1`. Zig names a shared
/// object `lib<name>.so.<major>.<minor>.<patch>` and gives it the soname
/// `lib<name>.so.<major>`, so upstream's two names are one value rather than
/// two conventions to reconcile. This is not a fork-chosen ABI number: it is
/// upstream's, read out of upstream's Makefile.
const abi_version: std.SemanticVersion = .{ .major = 1, .minor = 3, .patch = 2 };

/// The nine units of `OBJZ` (`src/Makefile.in:59`), in upstream's order.
///
/// Nothing is dropped and nothing is added. `adler32.c` and `crc32.c` are the
/// two checksum functions; `deflate.c`, `trees.c`, `inftrees.c`, `inffast.c` and
/// `inflate.c` are the compressor and decompressor; `infback.c` is the one-shot
/// `inflateBack` interface; `zutil.c` holds the shared internal helpers. A build
/// that dropped `infback.c` would lose `inflateBack`, `inflateBackInit` and
/// `inflateBackEnd`, all three of which `src/zlib.h:1113-1208` declares.
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

/// The six units of `OBJG` (`src/Makefile.in:60`): the `gz*` file layer.
///
/// `compress.c` and `uncompr.c` are the one-shot `compress`/`uncompress` pair
/// and `gzlib.c`, `gzread.c`, `gzwrite.c` and `gzclose.c` are the `gzFile`
/// stream. All six are here: `gzlib.c` holds `gzopen`, `gzseek`, `gztell`,
/// `gzoffset`, `gzeof`, `gzdirect`, `gzerror`, `gzsetparams`, `gzbuffer` and
/// `gzrewind`; `gzread.c` holds `gzread`, `gzfread`, `gzgets`, `gzgetc`,
/// `gzungetc` and `gzgets`-adjacent state; `gzwrite.c` holds `gzwrite`,
/// `gzfwrite`, `gzprintf`, `gzputs`, `gzputc` and `gzflush`; `gzclose.c` holds
/// `gzclose`, `gzclose_r` and `gzclose_w`. The facade wraps all of them.
const lib_sources = [_][]const u8{
    "src/compress.c",
    "src/uncompr.c",
    "src/gzclose.c",
    "src/gzlib.c",
    "src/gzread.c",
    "src/gzwrite.c",
};

/// The public headers, as upstream's own install rule states them.
///
/// `src/Makefile.in:343-347` is the citation and it names exactly two files.
/// `zconf.h` is *not* read from `src/`: it is the generated one, for the reasons
/// the module comment gives. It is listed here by name because `add_c_library`
/// installs headers by basename and `include/zconf.h` has to be that name.
const public_headers = [_][]const u8{
    "src/zlib.h",
};

/// The configured header, installed under upstream's name beside `zlib.h`.
const generated_header = "zconf.h";

/// The manual page upstream ships and installs under `man/man3`
/// (`src/Makefile.in:53`, `man3dir= ${mandir}/man3`, installed at `:334-336`).
/// The tarball also carries `src/zlib.3.pdf`; it is retained in `src/` with a
/// digest but is not installed, because upstream's install rule does not install
/// it either - `src/Makefile.in:357-358` builds it only for the `docs` target,
/// which needs `groff` and `ps2pdf`.
const man_pages = [_][]const u8{
    "src/zlib.3",
};

/// The licence and provenance records `zig build` installs under
/// `share/licenses/zlib/`.
///
/// zlib's own grant is two files in the tarball - `src/LICENSE` and the header
/// block of `src/zlib.h:1-29` - and both are installed here, because a package
/// that ships a binary and neither text has removed an obligation a private
/// repository does not remove. `src/README` is upstream's own release note, kept
/// byte for byte and also installed under the licence directory; the root-level
/// `README.upstream.md` is a byte-identical copy of it.
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

/// Language level for every C translation unit, pinned.
///
/// zlib is C89-and-later C and says so: `src/README:35-36` describes the release
/// as usable on "most flavors of Unix", and the code uses `long long` and
/// `//`-free declarations throughout. Upstream's own `configure` sets no
/// `-std=` at all and relies on the compiler default. Pinning `-std=gnu99` here
/// makes the dialect a fact of this build rather than a fact about whichever
/// clang or gcc the machine running `zig build` happens to name, and `gnu99`
/// rather than `c99` because `src/configure` itself passes GNU extensions to
/// the compiler for the test programs.
const c_flags = [_][]const u8{"-std=gnu99"};

/// Which `libz` the package links.
const Library = enum {
    /// Compiled from the pinned upstream C in `src/`.
    bundled,
    /// The installed library `systemIntegrationOption("zlib")` selected.
    system,
};

/// The cross-compilation matrix `check` walks when no target is named.
///
/// These are the six targets the workspace's own ledger names
/// (`FORKS.json`'s `cross_targets`), in the order this workspace uses
/// everywhere. Nothing is skipped and nothing here is pre-judged: if a target
/// cannot be satisfied on the machine running the gate, that is for the gate to
/// report.
///
/// Unlike a Lua-shaped SDK, every one of the six is expected to build. zlib's
/// closure is portable C plus a small, ordinary POSIX surface - `open`, `read`,
/// `write`, `lseek`, `close`, `fcntl` and `strerror`, all in `src/gzguts.h` and
/// `src/gzlib.c` - and the Windows row takes upstream's own `<io.h>` path at
/// `src/gzguts.h:50` instead. `refusalFor` exists and returns null for every
/// OS; `refused_check_targets` is empty. Both are kept so that a future
/// genuinely unbuildable target has a place to go and so that `check` proves
/// the six rows are the six it says they are.
///
/// The `wasm32-wasi` row names no `.abi`, so it resolves to `wasm32-wasi-musl`
/// and is built against a libc. Naming `.abi = .none` there resolved it to
/// `wasm32-wasi-none`, which the pinned toolchain gives *no* libc include path
/// at all, so the generated `zconf.h`'s `#include <sys/types.h>`
/// (`src/zconf.h.in:454-458`) failed with `'sys/types.h' file not found` in
/// every one of the fifteen units. `Platform.forTarget` below already labels
/// this OS `"wasi (musl)"`, so the query and the label disagreed; the query was
/// wrong, and the ledger's row (`FORKS.json`'s `cross_targets`, `"wasm32-wasi"`)
/// names no ABI either. This is the fork's own mistake and it is fixed here, not
/// recorded as a boundary.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Targets `check` must not walk, because this build refuses their OS.
///
/// Empty, and kept rather than deleted: `checkMatrixPartition` re-derives both
/// lists through the same `refusalFor` that `refuseTarget` stops with, so a
/// change that made a refused target buildable fails any build of this package
/// rather than quietly shrinking what `check` proves.
const refused_check_targets = [_]std.Target.Query{};

/// The name a compiled artifact carries in this build graph.
///
/// The published graph installs `libz.a` or `libz.so.1.3.2`, the name a C
/// consumer's `-lz` needs. A check graph installs nothing, so its artifacts carry
/// the target triple instead: six targets share one build graph, and six steps
/// all called "zlib" make `--summary all` impossible to read.
fn artifactName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    public: bool,
) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// The per-target configuration this build resolves, and the only place it is
/// computed.
///
/// Everything here is a function of `std.Target`, never of the host. That is the
/// whole point: the two `zconf.h` probe answers decide which system headers
/// zlib's own sources see, and a build host's answers would put the build
/// machine's configuration into a cross-compiled library.
const Platform = struct {
    /// A short name for the configure-time printout.
    kind: []const u8,
    /// The answer `tools/genzconf.c` takes for `HAVE_UNISTD_H`.
    have_unistd_h: bool,
    /// The answer `tools/genzconf.c` takes for `HAVE_STDARG_H`.
    have_stdarg_h: bool,
    /// Whether a Windows shared object needs zlib's `ZLIB_DLL` split.
    dll: bool,

    /// Resolve one target's answers.
    ///
    /// `HAVE_UNISTD_H` is false on Windows and true everywhere else, and the
    /// false is the Windows branch upstream itself takes rather than a
    /// limitation. `src/zconf.h:488-490` includes `<unistd.h>` only to get
    /// `SEEK_*` and `off_t`, and only when `Z_HAVE_UNISTD_H` is set; without it
    /// `src/zconf.h:518-519` defines `z_off_t` as `long long` and
    /// `src/zconf.h:511-514` defines `SEEK_SET`/`SEEK_CUR`/`SEEK_END` itself.
    /// That is exactly what upstream's Windows build uses: `src/gzguts.h:50`
    /// includes `<io.h>` there and `src/gzguts.h:46-49` includes `<stddef.h>`.
    /// Answering "yes" for `x86_64-windows-gnu` would additionally require a
    /// `<unistd.h>` that MinGW happens to have, and would make the installed
    /// `zconf.h` describe a Windows library that includes a header upstream's
    /// Windows path does not use.
    ///
    /// `HAVE_STDARG_H` is true for every target this SDK builds. Every module
    /// and archive here sets `link_libc = true`, and `<stdarg.h>` is mandatory in
    /// any hosted C implementation (C99 7.12), so the probe cannot fail. It is
    /// still an argument to the generator rather than a hard-coded rewrite,
    /// because the generator's contract is upstream's two probes and a caller
    /// that could answer "no" should not have to modify the generator to say so.
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
            // `src/zconf.h:344-352`: the `__declspec` split is behind
            // `#if defined(WINDOWS) || defined(WIN32)` and `#ifdef ZLIB_DLL`.
            // Upstream's own `win32/Makefile.gcc` defines `ZLIB_DLL` together
            // with `ZLIB_INTERNAL` for the DLL's own sources; this build does
            // the same, and only for a shared object.
            .dll = os_tag == .windows,
        };
    }
};

/// Produces the configured `zconf.h` for `target`, as a `LazyPath` created
/// inside the build function.
///
/// The generator is a host executable built by this build, so its answer is a
/// rewrite of bytes in this repository rather than a probe of anything. What
/// makes the result *target-specific* is entirely the two arguments, and they
/// come from `Platform.forTarget`.
///
/// The returned path is the header; `.path.dirname()` is the directory that has
/// to precede `src/` on four include lines. Each caller is responsible for
/// adding it, because the ordering is what makes the bare
/// `#include "zconf.h"` at `src/zlib.h:37` resolve to *this* header and not to
/// the unconfigured template that is also in the tree.
fn addZconf(b: *std.Build, target: std.Build.ResolvedTarget, platform: Platform) std.Build.LazyPath {
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    // The generator is a C program with its own `main`, and that `main` is the
    // one `tools/check-provenance.sh` builds with the host C compiler. So the
    // C file is added as a source file of a module that has no root source
    // file, rather than *being* a root source file: a module whose root source
    // file is a C file fails at compile time with `no module named 'root'
    // available within module 'std'` out of `lib/std/builtin.zig:5`, because
    // `std` resolves `@import("root")` through the compilation's root module
    // and a C-rooted module is not wired to it. The program is unchanged; only
    // the way the build graph names it is.
    const generator_module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        // `tools/genzconf.c:108-111` includes <stdio.h> and friends.
        .link_libc = true,
    });
    generator_module.addCSourceFile(.{ .file = b.path(zconf_generator) });
    const generator = b.addExecutable(.{
        // The name carries the target for the same reason the artifacts do:
        // `check` puts six of these in one graph.
        .name = b.fmt("zlib-genzconf-{s}", .{triple}),
        .root_module = generator_module,
    });

    const run = b.addRunArtifact(generator);
    // The template, read out of the tree rather than copied by hand: it is an
    // upstream file with a digest in `UPSTREAM.sha256`, and passing the path
    // means the generator's input is provably that file.
    run.addFileArg(b.path("src/zconf.h.in"));
    // `tools/genzconf.c:100` is the argument contract:
    // `<input> <output> <have_unistd:0|1> <have_stdarg:0|1>`. The output has to
    // be the *second* argument, so it is registered here and not at the end.
    // Appending it after the two probe answers put a path where
    // `genzconf.c:281-282` reads `output` and a `0`/`1` where it reads
    // `have_stdarg`, so the generator wrote the header to a file named after
    // the first probe answer in the build's working directory and never wrote
    // the `o/<hash>/zconf.h` the include paths point at.
    const zconf = run.addOutputFileArg(generated_header);
    run.addArg(if (platform.have_unistd_h) "1" else "0");
    run.addArg(if (platform.have_stdarg_h) "1" else "0");
    // Neither `--zprefix` nor `--solo`: this build requests neither, and the
    // generator reproduces both rewrites (`src/configure:677` and `:685`) only so
    // that asking for one would not mean editing a C file.
    return zconf;
}

/// One target's library and facade.
const Graph = struct {
    /// The compiled C library, or null in system mode, where nothing is
    /// compiled from this tree.
    c_lib: ?*std.Build.Step.Compile,
    /// The facade module, with `c` bound to the translated headers for the
    /// library this graph compiled or selected.
    module: *std.Build.Module,
    /// The platform this graph compiled for, so a caller that adds a step does
    /// not resolve the target a second time and risk disagreeing.
    platform: Platform,
    /// The generated `zconf.h` this graph compiled against, so the installed
    /// header and the compiled one cannot be different files.
    zconf: std.Build.LazyPath,
};

/// Builds one target's library and facade.
///
/// `public` chooses between the package module set, which is what a dependent
/// reaches through `dep.module("zlib")`, and a private module. A cross-target
/// check needs the private form: modules are registered by name against the
/// whole build, so registering `zlib` once per matrix target would leave only
/// the last of them reachable and silently stop checking the rest. The
/// translated headers are imported rather than registered in both forms; the
/// published routes are named above.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    // Every route into this file passes through here: `build` for the published
    // graph and for `-Dtarget=`, and `add_target_check` for each matrix cell.
    // `runConsumer` reaches it too, one process later: it shells out to a
    // nested `zig build` in `consumer/` that resolves this package as a
    // dependency, and that nested build runs this `build()`. The refusal is here
    // rather than in `build` so that naming the target by hand and walking the
    // matrix cannot be given two different answers. Nothing has been compiled
    // when this runs - it is a configure-time stop, not a warning hung off a
    // later step.
    if (refusalFor(target.result.os.tag) != null) refuseTarget(b, target);

    const platform = Platform.forTarget(target);
    // The header is generated whether or not a library is compiled from this
    // tree: in system mode it is still installed, and it is still the answer to
    // "which zconf.h describes this package". It is generated rather than read
    // so that `zig build -Dsystem` and `zig build` install the same bytes.
    const zconf = addZconf(b, target, platform);

    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, zconf, artifactName(b, target, public))
    else
        null;

    // The linkage this target can actually carry, resolved here so the
    // translation and the library cannot disagree about it. `add_c_library`
    // resolves the same value for the same reason.

    const translate = b.addTranslateC(.{
        .root_source_file = b.path(translate_header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The generated `zconf.h` directory comes FIRST, before `src/`.
    translate.addIncludePath(zconf.dirname());
    if (library == .bundled) {
        // `zig/translate.h` includes `<zlib.h>` and `<zconf.h>`, and without
        // this path the translation would bind to whatever zlib happens to be
        // installed on the build machine and describe that library's
        // declarations rather than the ones this graph compiles (`WISDOM.md`
        // W14). System mode deliberately does not add it: there the same two
        // lines are reached through the installed prefix `zlib.pc` names, never
        // through this tree.
        translate.addIncludePath(b.path(source_dir));
        // Putting `src/` on the path at all is what creates the shadowing, and
        // `-I` order cannot fix it: for a quoted `#include "zconf.h"` every C
        // compiler searches the directory of the *including file* - `src/`,
        // where `src/zlib.h` lives - before any `-I` directory, so the
        // unconfigured `src/zconf.h` won and `z_off_t`/`z_size_t` came out with
        // different widths than the compiled C lays out. A silent ABI
        // mismatch, not an error. `src/zlib.h:33-38` already carries the switch
        // for it: with `ZLIB_BUILD` defined the include is the angle-bracket
        // `<zconf.h>`, which searches only `-I` and system directories and so
        // finds the generated one first. The macro is read at `src/zlib.h:34`
        // and nowhere else in the tree, so this changes the spelling of one
        // include and nothing else.
        translate.defineCMacro("ZLIB_BUILD", "1");
    }

    // System mode: the installed `zlib.pc` names the include directory this
    // translation needs and the library the module binds, and this one call
    // gives both to both. `createModule` carries the entry onto the `c` module
    // below, so a dependent compiles and links against the same prefix the
    // declarations were read from.
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

    // `src/zlib.h`'s bytes, so `zig/root.zig` reads the version out of the
    // header this package compiled rather than restating it. The facade's own
    // package is `zig/`, so it cannot embed `../src/zlib.h`; see
    // `graph.addHeaderImport`.
    graph.addHeaderImport(b, module);
    // Where the runtime-loading seam is
    // ---------------------------------
    // `runtime/graph.zig`, which the API role owns, exposes
    //
    //     pub fn createModule(
    //         b: *std.Build,
    //         translate: *std.Build.Step.TranslateC,
    //         target: std.Build.ResolvedTarget,
    //         optimize: std.builtin.OptimizeMode,
    //     ) *std.Build.Module
    //
    //     pub fn createCoreModule(
    //         b: *std.Build,
    //         target: std.Build.ResolvedTarget,
    //         optimize: std.builtin.OptimizeMode,
    //     ) *std.Build.Module
    //
    // and `-Druntime` substitutes the first for `translate.createModule()`. It
    // takes the `TranslateC` step this function has already built, so the
    // generated dispatch keeps the exact translated type and constant namespace
    // rather than compiling a second copy of the native extern declarations and
    // casting between two nominally distinct Zig modules: `c.deflate` in the
    // facade and the declaration behind the table are one type.
    //
    // `-Dlinkage` is orthogonal and keeps meaning what it means: it selects
    // which artifact this build *delivers* and installs, never which one the
    // module dispatches through.
    //
    // The `rt` import is for the linked branch only, and the reason is the
    // nominal type rather than the code: `graph.createModule` creates the one
    // core-module instance the generated dispatch uses and re-exports
    // `LoadSource`/`LoadError` from it; a second instance created here for the
    // facade would be a *different* `LoadSource`, and `zlib.load(source)` would
    // be handing the facade's type to a function expecting the dispatch's. One
    // instance per build, no more. In a linked build there is no dispatch, so
    // the facade's own `rt` import is where those two public types come from;
    // `zig/root.zig` picks between the two with a comptime branch on
    // `runtime_loaded`, so the module a configuration does not need is never
    // resolved and never compiled.
    if (runtime_loaded) {
        // A loaded provider must arrive through the platform loader, so the link
        // line names nothing. Linking the archive as well would make the linker
        // resolve the same symbols statically and the runtime route would
        // quietly be a linked one. The artifact itself is still built and
        // installed, because delivery and dispatch are separate questions: the
        // whole point of the mode is that a caller may name a provider this tree
        // did not build.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // The translated headers are imported, never registered.
        // `addModule("c")` would make `dep.module("c")` resolve and hand a
        // dependent the same declarations without the library that satisfies
        // them; `zlib.c` on the facade is the supported way in and carries the
        // facade's own linkage.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        // System mode names the installed library through the translation above,
        // so this module already carries it.
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // The same two include paths as the archive's own module, in the same order,
    // on the module a dependent actually imports, so a dependent that compiles
    // its own C against this package finds the same `zconf.h` the core was
    // compiled with. System mode does not add `src/`: the installed include
    // directory reaches the dependent through the same `zlib.pc` entry, and the
    // installed `include/zconf.h` is already the configured one.
    module.addIncludePath(zconf.dirname());
    if (library == .bundled) module.addIncludePath(b.path(source_dir));

    return .{ .c_lib = c_lib, .module = module, .platform = platform, .zconf = zconf };
}

/// Compiles the C library for one target: `OBJC`, and nothing else.
///
/// `requested` is the linkage the caller asked for. What it selects is the
/// artifact and nothing else about the compilation. What a shared artifact adds
/// is its own requirements - the soname, PIC, the export surface and the DLL
/// macro split - and `delivered` is what this target can actually carry.
///
/// `name` is the artifact name this graph installs or reports; see
/// `artifactName`.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    requested: std.builtin.LinkMode,
    platform: Platform,
    zconf: std.Build.LazyPath,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        // See "Static and shared delivery" for where `abi_version` comes from.
        // `version` is null for a static archive, which has no soname and no
        // versioned file name.
        .version = if (linkage == .dynamic) abi_version else null,
        .win32_module_definition = if (linkage == .dynamic and target.result.ofmt == .coff)
            b.addWriteFiles().add("zlib.def", @embedFile("src/win32/zlib.def"))
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // libc, because every unit of `OBJC` reaches the C library for its
            // own vocabulary: `src/zutil.h:28-29` opens `<string.h>` and
            // `<stdlib.h>` and every unit includes `zutil.h` or `zlib.h`;
            // `src/gzguts.h:32-37` opens `<stdio.h>`, `<string.h>`, `<stdlib.h>`
            // and `<limits.h>` for the five `gz*` units; `src/trees.c:40` opens
            // `<ctype.h>`; and `src/gzguts.h:43` opens `<fcntl.h>` on POSIX.
            .link_libc = true,
            // A shared library is position-independent whether or not this says
            // so; naming it makes the requirement explicit, and it is what
            // upstream's `src/Makefile.in:63-65` `PIC_OBJ*` lists exist for.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    // The generated `zconf.h` directory first, then `src/`.
    c_mod.addIncludePath(zconf.dirname());
    // For the sources' own quoted includes: every file in `src/` includes its
    // neighbours by bare name.
    c_mod.addIncludePath(b.path(source_dir));
    // `src/zlib.h:33-38` includes `zconf.h` by bare name, and bare-name order
    // on the `-I` line is not what decides it: a quoted `#include "zconf.h"`
    // searches the directory of the *including file* first, and the including
    // file is `src/zlib.h`, so the unconfigured `src/zconf.h` was always the
    // one found. With it, `src/zconf.h:446-448` and `:450-452` take the `-0`
    // branch, `Z_HAVE_UNISTD_H` is never defined, `src/zconf.h:488-490` never
    // reaches `#include <unistd.h>`, and the `gz*` units fail on undeclared
    // `write`, `read`, `lseek` and `close`.
    //
    // `src/zlib.h:34` is the switch upstream already provides: with
    // `ZLIB_BUILD` defined the include is the angle-bracket `<zconf.h>`, which
    // searches only `-I` and system directories and therefore finds the
    // generated header first, exactly as the two lines above are ordered for.
    // The macro is read at `src/zlib.h:34` and nowhere else in the tree, so
    // this changes the spelling of one include and nothing else. It is not one
    // of the configuration macros `src/configure` would define, and it is not
    // installed or exported - see "No mandatory compile macros on POSIX".
    c_mod.addCMacro("ZLIB_BUILD", "1");

    // The Windows DLL macros, and only where `__declspec` exists.
    // `src/zconf.h:344-352` puts the split behind `#if defined(WINDOWS) ||
    // defined(WIN32)` and `#ifdef ZLIB_DLL`, and `:346-352` chooses
    // `__declspec(dllexport)` when `ZLIB_INTERNAL` is also defined and
    // `__declspec(dllimport)` when it is not. So the library's own sources get
    // `ZLIB_DLL` + `ZLIB_INTERNAL` and a consumer gets `ZLIB_DLL` alone, exactly
    // as upstream's own `win32/Makefile.gcc` does. Everywhere else
    // `src/zconf.h:389-394` leaves `ZEXTERN extern` and `ZEXPORT` empty, so
    // defining them on an ELF or Darwin build would be inert.
    //
    // The guard is the configured header, not `src/zconf.h`: this is a macro of
    // the compiled configuration, and the configuration is what the generator
    // wrote. Nothing in `zig/translate.h` needs it - see the comment there -
    // because the consumer half of the split is the installed header's job, and
    // `add_pkg_config` is where a Windows shared build records it.
    const windows_dll = platform.dll and linkage == .dynamic;
    if (windows_dll) {
        c_mod.addCMacro("ZLIB_DLL", "1");
        c_mod.addCMacro("ZLIB_INTERNAL", "1");
    }

    // No `-D` of this build's own on any POSIX target: see the module comment
    // under "No mandatory compile macros on POSIX" for what upstream's
    // `configure` would have added and why every one of those probes succeeds.

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

    // Upstream's own link libraries, and only those: `src/Makefile.in:43` is
    // `LDSHAREDLIBC=-lc` and nothing else is on the link line, because the whole
    // of `OBJC` is either libc's C or libc's POSIX. zlib links no `-lm`, no
    // `-lpthread` and no `-ldl`; there is no floating-point arithmetic in the
    // library and no dynamic loading of its own.

    if (linkage == .dynamic) setVersionScript(b, c_lib, target);

    // Installing the headers also puts them on the include path of anything
    // that links this artifact, so a C consumer needs nothing from this tree to
    // call it. `src/zlib.h` is read out of `src/`; `zconf.h` is the *generated*
    // one, because `src/Makefile.in:346` installs the configured header and not
    // the template. These two are the whole of upstream's installed header list.
    for (public_headers) |header| {
        c_lib.installHeader(b.path(header), std.fs.path.basename(header));
    }
    c_lib.installHeader(zconf, generated_header);

    return c_lib;
}

/// Gives a shared library the export surface upstream asks for.
///
/// Two files, both read out of the tree rather than rewritten here, because
/// upstream's export lists are the contract and a restatement of them could
/// disagree with them without anything noticing:
///
///   * `src/zlib.map` is the ELF version script. `src/configure:290-292` and
///     `:299-300` hand it to the linker as
///     `--version-script,${SRCDIR}zlib.map` on Linux and the BSDs, and
///     `src/Makefile.in:288` lists it as a prerequisite of `$(SHAREDLIBV)`.
///     Its last node is `ZLIB_1.3.2`, so the symbol versions this build exports
///     are upstream's own.
///   * `src/win32/zlib.def` is the COFF export list, passed to the linker by
///     `add_c_library` as `win32_module_definition`. Mach-O has no version
///     script that GNU ld or lld reads the same way, so this does nothing for
///     Darwin; `build` prints that rather than hiding it.
fn setVersionScript(
    b: *std.Build,
    c_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.ofmt != .elf) return;
    const files = b.addWriteFiles();
    c_lib.setVersionScript(files.add("zlib.map", @embedFile("src/zlib.map")));
}

/// Compiles the library, the facade, the tests and the example for one
/// cross-target matrix cell, running nothing.
///
/// `cross_target` is the cell's resolved target, not the host: the fifteen C
/// units, the translation and the generated `zconf.h` are all built for it.
/// An install is compile evidence and not a claim that a cross-built binary
/// executed.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // The triple names the cross artifacts. Six targets in one build graph
    // otherwise produce six steps called "zlib", which makes `--summary all`
    // useless for telling them apart.
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

    // In system mode there is no artifact from this tree to compile, and
    // installing an empty stand-in would be a claim this build cannot make.
    if (cross.c_lib != null) {
        step.dependOn(&cross.c_lib.?.step);
    }
}

/// Runs the consumer package as its own `zig build` in `consumer/`.
///
/// The consumer is a separate package on purpose: a manifest dependency here
/// would close a cycle, because its manifest points back at this package by
/// path. Running it as a separate build is what makes the proof real - that a
/// package which only writes `b.dependency("zlib", ...)` and
/// `dep.module("zlib")` gets a working, correctly linked library, with the
/// archive and libc arriving through the module and nothing else.
///
/// Everything this build resolved travels with it: the target and CPU, the
/// optimize mode, the library mode, the linkage and dispatch shapes, the
/// executor switches, both cache directories, the install prefix, the job width
/// and the summary. An argument left behind would be a proof of a
/// configuration nobody asked for.
///
/// Run when this host can execute the selected target, and install otherwise:
/// `hostCanExecute` asks exactly what `std.Build.Step.Run` asks of a foreign
/// binary, so the decision here and the nested run cannot disagree. An executor
/// counts only when its `-f` switch was given; a target with none installs,
/// which is compile evidence and never a semantic pass.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // The same query's other half. The triple above names the architecture, the
    // OS and the ABI; it carries no CPU model and no feature set, and `cpu` is a
    // separate option of its own. `serializeCpu` writes `native` for a query that
    // named no CPU and `baseline` for a cross query that named none, and
    // `Target.Query.parseCpu` recognises both spellings, so the nested
    // `standardTargetOptions` resolves this build's selection rather than one of
    // its own. `addArg` copies each argument, so these temporaries can go right
    // after.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // `b.graph.zig_exe` is the compiler running this build script, so the nested
    // build is the same toolchain rather than whatever is on PATH.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    // The model and its feature set, for the reason the serialization above
    // gives. Without it the nested build would compile the consumer at a
    // baseline CPU on a host that built the library for something else, and the
    // step would prove a configuration nobody asked for.
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // The delivery and dispatch options have to reach the nested build or the
    // consumer would silently check the default graph and say nothing about the
    // configuration that was asked for.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    // Both spellings go, not only the true one, so a cell's configuration is
    // stated rather than inferred from a default and the flag cannot be dropped
    // on the way down. `consumer/build.zig` reads the option and hands it to
    // `b.dependency("zlib", ...)`, and that value is what
    // `consumer/src/main.zig` branches on at comptime.
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    // The mode *this* build resolved, which is a different question from which
    // option asked for it. `b.systemIntegrationOption` is fed by the build
    // runner's `-fsys=`/`-fno-sys=` flags and is never an entry in the `-D` map,
    // so forwarding `-Dsystem` would set the nested graph's *default* and leave
    // the answer to that graph's own runner instead of this build's. Both
    // spellings go, so the dependency's own
    // `systemIntegrationOption(lib_name, ...)` resolves the answer this build
    // already reached: a dependency shares its parent's `Graph` and
    // `system_library_options` is a field of it.
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    // Forward the selected executor and its dynamic-linker support.
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // The nested build carries this workspace's job count and summary in its own
    // command line. Nothing can append a `-j` to a `Run` step's command, so a
    // nested build left to derive its own width takes `cpu_count - 1` instead,
    // and the consumer this step proves then compiles at a different width from
    // the build that asked for it - and at a different width again on whichever
    // machine runs the gate. `--summary all` is for the same reader: the nested
    // build is a separate graph whose steps are named after the consumer
    // package, and a failure inside it is otherwise one unnamed line.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // A null `path` means "the current directory", and the working directory is
    // already the consumer package, so the default is right.
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // The global cache is inherited whole rather than subdirectoryed: it is one
    // shared store of packages and hashes, so a nested build left to resolve
    // its own would fetch again what this one already holds, and would write
    // outside the root this workspace approved.
    if (b.graph.global_cache_root.path) |global_cache| {
        run.addArg("--global-cache-dir");
        run.addArg(global_cache);
    }
    // The install prefix this invocation resolved, handed on when the caller
    // named one. A nested `zig build` left to resolve its own installs into
    // `consumer/zig-out` - a build artefact inside a source package - rather
    // than into the directory the caller asked for. A relative `--prefix` would
    // resolve against the working directory set above, `consumer/`, and not
    // against this build's root, so it is made absolute before it is handed on.
    // `DESTDIR` needs no forwarding, because the nested build inherits the
    // environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // The caller's own arguments, last and behind `--`: `--` is where the build
    // runner stops parsing options and keeps the rest as `b.args`, so this `--`
    // has to follow every argument above - those are this package's own
    // bookkeeping with the nested build, and only what the caller typed after
    // `--` belongs to the program. `consumer/src/main.zig` documents
    // `--provider <path>` as a command-line input, and this is the only place
    // those words can enter the nested graph at all. `consumer/build.zig`
    // forwards its own `b.args` to the run step, so what lands here reaches
    // `src/main.zig` on the second hop unchanged.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    // The nested build is the step's only observable effect.
    run.has_side_effects = true;
    return run;
}

/// True when this build can execute `target`'s binaries.
///
/// `std.zig.system.getExternalExecutor` is the predicate
/// `std.Build.Step.Run` applies to the artifact it is about to spawn, and
/// `allow_*` carries this build's own executor switches, so the two cannot
/// disagree. `link_libc` holds in every mode this package builds; the `.qemu` arm
/// carries `Run`'s own second gate.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // `consumer/` builds its executable with `b.addExecutable` and no
        // linkage, so `Run`'s musl half of `need_cross_libc` never holds here.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Reachable only for an executor the switches above enabled, each of
        // which `Run` gates on the same switch and nothing else.
        .wine, .wasmtime, .darling => true,
        // Not a yes on its own: `Run` fails a cross GNU libc target given no
        // `--libc-runtimes`, so this step installs it instead. Every other QEMU
        // case still runs.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        // Same OS and CPU with no dynamic linker to load, or an architecture
        // and system this build has no enabled executor for.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

/// Writes `lib/pkgconfig/zlib.pc` and installs it.
///
/// zlib ships the template this file's fields come from: `src/zlib.pc.in` is in
/// the tarball and `src/Makefile.in:337-338` installs the `zlib.pc` that
/// `configure` wrote from it. So this is not a new file format - it is upstream's
/// own, with `@VERSION@` substituted and the five path variables made
/// relocatable:
///
///   * `Name`, `Description`, `Version`, `License` - verbatim from
///     `src/zlib.pc.in:7-11`. `Version` is `upstream_version` rendered as
///     upstream's `configure` renders it into `zlib.pc.in`'s `@VERSION@`; the
///     `configure-time comparison against `manifest_version` is what keeps it
///     from being a third independent spelling.
///   * `prefix` is `${{pcfiledir}}/../..` rather than a substituted absolute path.
///     This graph does not know where `--prefix` will point when it writes the
///     file, and pkg-config resolves `${{pcfiledir}}` against the `.pc` it found,
///     so the installed file is correct wherever the prefix landed - including a
///     Nix store path that is only known at build time.
///   * `Libs` is `-L"${{libdir}}" -L"${{sharedlibdir}}" -lz` in both variants,
///     because the library *name* does not change with linkage: a C consumer asks
///     for `-lz` and the linker resolves it to `libz.a` or, through the
///     `libz.so` symlink, to the shared object. Both `-L` entries are upstream's,
///     and both are kept rather than collapsed because `src/Makefile.in:50-51`
///     makes them independently configurable.
///   * `Libs.private` is empty. `src/Makefile.in:43` is `LDSHAREDLIBC=-lc` and
///     nothing else, so a static consumer needs libc and nothing further.
///   * `Cflags` is `-I"${{includedir}}"`, plus `-DZLIB_DLL` for a Windows shared
///     build. That flag is what makes `src/zconf.h:344-352` decorate a consumer's
///     declarations `__declspec(dllimport)` on Windows, which is the half of
///     upstream's DLL split a consumer of the shared object needs. It is Windows-
///     and dynamic-only: without `__declspec` the macro is inert, and upstream's
///     own `win32/Makefile.gcc` only defines `ZLIB_DLL` for the DLL.
fn add_pkg_config(
    b: *std.Build,
    platform: Platform,
    target: std.Build.ResolvedTarget,
    linkage: std.builtin.LinkMode,
) void {
    const files = b.addWriteFiles();
    const windows_dll = platform.dll and deliveredLinkage(target, linkage) == .dynamic;
    // The returned step is bound to the install step. `addInstallFileWithDir`
    // *creates* a `Step.InstallFile` and nothing more - dropping the return value
    // builds nothing and installs nothing, and the omission is silent.
    // Upstream's `configure` substitutes a plain three-component version into
    // `src/zlib.pc.in`'s `@VERSION@`. Zig's `SemanticVersion` renders as
    // `major.minor.patch`, which is that string for every 1.x release, so the
    // two spellings agree without a second format - and the configure-time
    // comparison against `manifest_version` is what stops it becoming a third
    // independent spelling of the release.
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
        // The returned step is bound to the install step; dropping it builds
        // nothing and installs nothing, and the omission is silent.
        const install_record = b.addInstallFile(
            b.path(record),
            b.fmt("share/licenses/zlib/{s}", .{std.fs.path.basename(record)}),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

/// Installs the manual page under `share/man/man3`, where upstream puts it.
fn install_man_pages(b: *std.Build) void {
    for (man_pages) |page| {
        const install_page = b.addInstallFile(
            b.path(page),
            b.fmt("share/man/man3/{s}", .{std.fs.path.basename(page)}),
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
        std.builtin.LinkMode,
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

    // Two defaults, because the two modes had two. The bundled graph compiled a
    // static archive before this option existed and must keep doing so, because
    // `src/Makefile.in:38` names `STATICLIB=libz.a`; `linkSystemLibrary`'s own
    // default is `.dynamic`, and system mode must keep that too. Deriving one
    // from the other would silently change a consumer's linkage in the mode that
    // option was not written for.
    const linkage: std.builtin.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // `-Druntime` selects the *dispatch*, and it is orthogonal to `-Dlinkage`:
    // the option says which artifact this build delivers and installs, this one
    // says whether the Zig facade calls it through a link line or through a
    // table an explicit `load` fills. Under `-Druntime` nothing is linked into
    // the facade module at all, so a caller may name a provider this tree did
    // not build - and the artifact is still built and installed, so a caller may
    // equally name the one it did.
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

    // `build.zig.zon .version` and the version this build stamps into `zlib.pc`,
    // names into the shared object's file name and documents in four other
    // places are one fact. `std.SemanticVersion.parse` fails loudly rather than
    // wrapping a non-version, and the comparison catches a manifest edited
    // without the source it describes.
    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches ZLIB_VERSION in " ++
            "src/zlib.h:44; see UPSTREAM.md");
    }

    // Two lists, one decision function, checked before any graph is
    // configured: a row cannot be quietly wrong in either direction, and a
    // caller finds out from `zig build` rather than from a gate.
    checkMatrixPartition(b);

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    // In system mode there is no artifact from this tree to install, and
    // installing an empty stand-in would be a claim this build cannot make.
    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b, published.platform, target, linkage);
        install_licence_records(b);
        install_man_pages(b);
    }

    // `zig build` also compiles the example. The example is the cheapest thing
    // that proves the facade, the translated headers and the C archive agree on
    // types, symbols and link-time dependencies. It is compiled, not installed:
    // it is a proof, not a deliverable - and upstream installs no executable
    // either, which is why this package builds none.
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

    // A run artifact already depends on building the executable, which depends
    // on compiling the C and linking the facade. `zig build smoke` deliberately
    // does not depend on the install step: installing is `zig build`'s job and
    // conflating the two would make a smoke run depend on the install layout.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    if (b.args) |args| run_example.addArgs(args);
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // The test root is `tests.zig`, which names the test blocks; a root that
    // only re-exported them would discover no tests and still exit zero.
    // `addRunArtifact` is used rather than a plain compile so that this is a
    // real runnable test step for whatever `-Dtarget` names: a foreign target is
    // left to whichever executor the cross-test harness detects, and this build
    // does not decide that.
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

    // The separate consumer package, built as its own `zig build`. It runs when
    // this host can execute the selected target and installs when it cannot,
    // which is `hostCanExecute` rather than a query predicate: a cross-compiled
    // consumer binary cannot run here, and a native one can run under an enabled
    // executor. An install is compile evidence and nothing more.
    //
    // `library` is the mode `build` resolved, not the option a caller typed, so
    // the nested build is asked for the configuration this build is actually in.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // The cross target gate. Compiling the tests, the example and the whole
    // `OBJC` closure for each target is what makes this a check of the facade
    // rather than of an unreferenced archive. Nothing runs here.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests and the example for " ++
            "the six check targets without running any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, library, linkage, runtime_loaded);
    } else {
        // One matrix, whatever the delivery. `[0..]`, not `.*`: `.*` is for
        // dereferencing a single optional or error-union payload, so the
        // pointer-to-array has to become a slice before it can be iterated.
        for (check_targets[0..]) |query| {
            add_target_check(b, check_step, query, optimize, library, linkage, runtime_loaded);
        }
    }

    // Which platform configuration this graph compiled, which `zconf.h` it
    // generated and which artifact it hands back are facts worth reading out of
    // the build rather than inferring from a cache directory. These are
    // configure-time lines, not gate results: nothing has been compiled when they
    // print.
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
            // Dispatch is a separate fact from delivery, and a runtime-loaded
            // build links nothing into the facade module: the caller names a
            // provider with an explicit `load(source)` and the symbols arrive
            // through the platform loader. Printing it here is what keeps "the
            // library is still built and installed" from reading as "the module
            // links it".
            std.debug.print(
                "zlib: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        // A Mach-O shared object has no version-script mechanism here, so it
        // exports zlib's internal symbols as well as its API. Said rather than
        // left to be discovered by `nm -D`.
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

/// Whether this target's OS has a dynamic linker at all, and therefore whether
/// it can carry a shared object.
///
/// Windows uses its PE/COFF loader without an interpreter path.
/// Other shared targets need a dynamic linker. WASI has neither.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// The linkage this build delivers, or a refusal when the target cannot carry
/// what was asked for.
///
/// There is no substitution here, deliberately. A caller who asks for a shared
/// object has asked for a real shared object; handing back an archive under that
/// name would be a result the caller did not request and cannot tell from
/// support. So a shared request on a target whose OS has no dynamic linker stops
/// here, with a message that names the target, the reason and the way out.
///
fn deliveredLinkage(
    target: std.Build.ResolvedTarget,
    requested: std.builtin.LinkMode,
) std.builtin.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        // `std.debug.panic` with a format string, not `@panic` on a
        // concatenated string: `@tagName` of a run-time tag is not comptime
        // known, and `++` on a slice being concatenated has to be, so the
        // message is formatted at run time.
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

/// Why a target has no buildable zlib here, or null when it has one.
///
/// A summary line and a long form, and nothing else: no warning, no fallback,
/// no substituted function.
///
/// **There is currently no entry.** zlib's `OBJC` closure is portable C plus a
/// small POSIX surface - `open`, `read`, `write`, `lseek`, `close`, `fcntl` and
/// `strerror`, reached from `src/gzguts.h:43-51` and `src/gzlib.c` - and
/// Windows takes upstream's own `<io.h>` path instead (`src/gzguts.h:50`). All
/// six `check_targets` are expected to build. The function is kept because the
/// mechanism is what makes that a statement this build checks at configure time
/// rather than a hope: the moment a real refusal exists it is an entry here, and
/// `refused_check_targets` names the target it applies to.
const Refusal = struct {
    /// One line, printed with the target triple in front of it.
    summary: []const u8,
    /// The long form printed before the build fails.
    detail: []const u8,
};

fn refusalFor(os_tag: std.Target.Os.Tag) ?Refusal {
    // Intentionally no arm. See the type's doc comment.
    _ = os_tag;
    return null;
}

/// Prints why `target` cannot be built, and fails the build.
///
/// A real refusal, not a warning and not a stub: `zig build`, `zig build check`
/// and `zig build check -Dtarget=<this target>` all stop here, before a compiler
/// is invoked, and `zig build consumer -Dtarget=<this target>` stops in the
/// nested build it launches - which is this package's own `build()` again.
/// `addGraph` is the only caller.
fn refuseTarget(b: *std.Build, target: std.Build.ResolvedTarget) noreturn {
    const refusal = refusalFor(target.result.os.tag) orelse
        @panic("build.zig internal error: refusalFor returned null for a target addGraph refused");
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    std.log.err("zlib: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    @panic("zlib: refusing a target this package has no buildable configuration for");
}

/// Keeps the two halves of the matrix honest against each other.
///
/// The point of naming `refused_check_targets` is that the row is not quietly
/// absent, and the point of naming `check_targets` is that every row in it is
/// real. Both are re-derived here through the same `refusalFor` that
/// `refuseTarget` stops with, so a change that makes a refused target
/// buildable fails any build of this package rather than quietly shrinking what
/// `check` proves.
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
