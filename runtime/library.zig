// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.
//
//! zlib's side of the runtime loader: the names its synchronization binding
//! has, what it requires of a provider beyond resolving its symbols, and what
//! the external ABI boundary for this provider actually is.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them zlib's,
//! and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! Every entry point `zig/translate.h` declares for this configuration. `Z_SOLO`
//! is never defined by this build (see `FORK-NOTES.md`), so the `gz*` half is
//! present and a provider is expected to export it;
//! `provider_optional` and `provider_excluded` in `runtime/graph.zig` are both
//! empty and a provider that does not export the whole set is refused rather
//! than half used.
//!
//! ## The ABI boundary, stated honestly
//!
//! The supported external ABI family is **zlib 1.3.2** as built from
//! `src/zlib.h` and the *configured* `src/zconf.h` with no configuration macro
//! defined. That is a narrower claim than "a shared object that exports these
//! names", and the difference is real:
//!
//!   * `uInt` is `unsigned int` (`src/zconf.h:405`) and `uLong` is
//!     `unsigned long` (`src/zconf.h:406`), so `compress` takes a 32-bit length
//!     and a 64-bit length on the same LP64 and ILP32 targets respectively.
//!     `zlibCompileFlags` reports exactly this, in bits 1.0 and 3.2
//!     (`src/zlib.h:1218-1223`), which is why check 2 below reads the flags
//!     rather than assuming them.
//!   * `z_stream` (`src/zlib.h:90-110`) is a *by-value* struct that the caller
//!     fills in and the library reads and writes: `next_in` (`:91`),
//!     `avail_in`, `next_out`, `avail_out`, `total_in`, `total_out`,
//!     `msg` (`:99`), `state`, `zalloc`, `zfree` and `opaque`. A provider that
//!     disagrees about its size or layout is reading and writing the wrong
//!     bytes. `deflateInit2_` and `inflateInit2_` are handed
//!     `(int)sizeof(z_stream)` (`src/zlib.h:1927-1932`) and upstream's own
//!     `zutil.c`/`inflate.c` compare it, but only *after* the caller has already
//!     built the struct.
//!   * `gzFile` (`src/zlib.h:1354`) is opaque and its size is the provider's
//!     business, so nothing here reads through it.
//!   * The allocator is the provider's *and* the caller's. `zalloc` and `zfree`
//!     are two function pointers in the stream (`src/zlib.h:103-104`): left
//!     null, the library calls libc's `malloc`, `realloc` and `free` through
//!     `zutil.c`'s `zcalloc`/`zcfree`; set, it calls the caller's. Memory
//!     therefore crosses into libc's allocator with no Zig allocator in the
//!     path, and `std.testing.allocator` cannot be a leak oracle for it.
//!   * `z_stream.msg` is a `z_const char *` (`src/zlib.h:99`) written *by the
//!     provider* (`src/zutil.c` and the `gz*` units do the writing). It points
//!     at storage the provider owns, and it stays valid until the stream is
//!     ended. This module never frees it and never copies it.
//!
//! **A prefixed provider is refused, and it is refused before this file runs.**
//! `Z_PREFIX` (`src/zconf.h:17-18`) renames every public symbol: `adler32`
//! becomes `z_adler32` (`src/zconf.h:26`), `compress2` becomes `z_compress2`
//! (`:34`), `compressBound` becomes `z_compressBound` (`:36`), and so on. Such
//! an object exports none of the names the table wants, so symbol resolution
//! fails with `MissingSymbol` and `validate` is never reached. That is not a
//! check this file could have written; it is a fact about where the rename
//! happens.
//!
//! ## Which configuration macros `zlibCompileFlags` actually reports
//!
//! `zlibCompileFlags` (`src/zlib.h:1216`, documented at `:1217-1253`) reports
//! exactly what its own comment lists. Of the macros worth refusing, two have a
//! bit and two do not:
//!
//!   * **bit 8, `ZLIB_DEBUG`** (`src/zlib.h:1226`) - a debug build. Refused by
//!     check 2.
//!   * **bit 10, `ZLIB_WINAPI`** (`src/zlib.h:1228`) - "exported functions use
//!     the WINAPI calling convention". `src/zconf.h:357-367` shows what that
//!     does: `ZEXPORT` becomes `WINAPI` and `ZEXPORTVA` becomes `WINAPIV`, so
//!     every exported function is declared `__stdcall` instead of `__cdecl`.
//!     On the 32-bit Windows ABI that is a different calling convention under
//!     identical symbol names. Refused by check 2.
//!   * **`Z_PREFIX`** - **no bit exists for it.** Caught earlier, as above.
//!   * **`ZLIB_CONST`** - **no bit exists for it.** `src/zconf.h:245-251` turns
//!     `z_const` into `const` when it is defined, which changes what the *C
//!     compiler* accepts for `z_stream.next_in` (`src/zlib.h:91`),
//!     `z_stream.msg` (`:99`) and `inflateBack`'s callback signature (`:1135`).
//!     It changes no code generation and no symbol name, so **no load-time
//!     check can detect it**: a `ZLIB_CONST` provider and a plain one are the
//!     same object file with different qualifiers on the same pointers. It is
//!     refused at compile time, by `build.zig` not defining it, and that is the
//!     only place it can be caught.
//!   * **`GZIP_CONST`** - **this macro does not exist in zlib 1.3.2.**
//!     `grep -rn GZIP_CONST src/` returns nothing: not in `zlib.h`, not in
//!     `zconf.h`, not in the ChangeLog. It was a 1.2.x spelling whose role 1.3.2
//!     gives to `ZLIB_CONST` (`src/zconf.h:245-246`). It is named here so that
//!     the absence is recorded rather than papered over, and there is nothing to
//!     check because there is nothing to be set.
//!
//! ## What is checked at load time, and what is deliberately not
//!
//! Four checks run after every symbol resolved and before anything is
//! published. Each is one whose failure this code can observe; see the module
//! comment for the configurations that are caught earlier or not at all.
//!
//! Not called: `deflateInit_` and `inflateInit_` (`src/zlib.h:1903-1915`). They
//! are upstream's own version-and-size check, and it is worth saying why the
//! facts it checks are re-derived here instead. `deflateInit_` returns
//! `Z_VERSION_ERROR` when `version[0] != ZLIB_VERSION[0]` or
//! `stream_size != sizeof(z_stream)` (`src/deflate.c:326-338`), which would be a
//! correct check - but calling it needs a `z_stream` the caller has already
//! laid out at this SDK's idea of the size, and a mismatch would be reported
//! after the struct was already read. Check 1 answers the version half with
//! nothing to lay out, and check 4 sizes a one-shot buffer rather than
//! committing to a `z_stream` at all.
//!
//! Also not called: anything that writes through a pointer the caller supplies
//! and cannot be checked afterwards - `deflateSetDictionary`, `inflateCopy`,
//! `inflateSetDictionary`, the `gz*` file functions. None of them can fail in a
//! way that says "this is not the library these headers describe".

const std = @import("std");

const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.c` compiled with
/// `RT_SYNC_PREFIX=zlib_rt`, which is what `runtime/graph.zig` passes. Two
/// spellings of that prefix have to agree: this file names the symbols, and
/// graph.zig defines the macro. A build where they disagree does not link, and
/// that is the whole error report: there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn zlib_rt_lock() void;
    extern fn zlib_rt_unlock() void;
    extern fn zlib_rt_wait() void;
    extern fn zlib_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
    extern fn zlib_rt_thread_self() u64;

    pub fn lock() void {
        zlib_rt_lock();
    }
    pub fn unlock() void {
        zlib_rt_unlock();
    }
    pub fn wait() void {
        zlib_rt_wait();
    }
    pub fn broadcast() void {
        zlib_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return zlib_rt_thread_self();
    }
};

/// `src/zlib.h`, embedded so that the version this SDK expects is read out of
/// the header it actually compiled rather than restated here.
///
/// A second copy of "1.3.2" in a Zig file is a second fact that can drift from
/// `src/zlib.h:44` and from `build.zig.zon .version` without anything noticing.
/// Embedding makes the check below a statement about the pinned header.
///
/// The bytes come through the `zlib_header` import: this module's package is
/// `runtime/`, and the compiler answers `embed of file outside package path`
/// for an `@embedFile("../src/zlib.h")`. `build.zig` copies the header beside a
/// generated root - see `graph.addHeaderImport`.
const zlib_header = @import("zlib_header").bytes;

/// The `#define ZLIB_VERSION "..."` line out of the embedded header, as the
/// bytes between the first pair of quotes on it.
///
/// Returns null when the line is not there, which is a build error rather than
/// a load-time refusal: this is comptime, over a file in the package.
const expected_version: ?[]const u8 = blk: {
    const needle = "#define ZLIB_VERSION \"";
    const start = std.mem.indexOf(u8, zlib_header, needle) orelse break :blk null;
    const body = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, zlib_header, body, '"') orelse
        break :blk null;
    break :blk zlib_header[body..end];
};

/// Bit 8 of `zlibCompileFlags`: `ZLIB_DEBUG` (`src/zlib.h:1226`).
const flag_debug: u32 = 1 << 8;

/// Bit 10 of `zlibCompileFlags`: `ZLIB_WINAPI` (`src/zlib.h:1228`).
const flag_winapi: u32 = 1 << 10;

/// The payload check 3 compresses and decompresses. Long enough that
/// `compressBound` has to work for a real input and short enough that the
/// buffer below is comfortably larger than any bound a conforming provider can
/// return for it.
const probe_input = "zlib runtime provider validation payload";

/// `compressBound`'s answer for `probe_input`, as a ceiling this file imposes on
/// the provider rather than trusting it: `src/zlib.h:1298-1306` documents the
/// function as "an upper bound", and a provider claiming a larger one is refused
/// rather than allowed to size a buffer this stack frame owns.
const probe_input_len = probe_input.len;
const probe_output_max = 1024;

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "zlib";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated headers, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// The library-specific checks, run after every symbol resolved and
        /// before anything is published.
        ///
        /// A non-null answer is `ValidationFailed` and the candidate is closed
        /// without being published. See the module comment for what is
        /// deliberately not called and why.
        pub fn validate(dst: *const table) ?[]const u8 {
            const expected = expected_version orelse return
                "the embedded src/zlib.h has no ZLIB_VERSION definition, so this " ++
                "loader cannot state what it expects a provider to report";

            // Check 1: the version family.
            //
            // `zlibVersion` (`src/zlib.h:224`) returns the string the provider
            // was compiled with, and it is the same string that
            // `deflateInit_` compares against `ZLIB_VERSION`
            // (`src/deflate.c:326-330`). A provider from a different 1.x minor
            // or a different major is a different library under these symbol
            // names, so the check is a prefix test rather than equality: a
            // provider may carry a vendor suffix, which is exactly what
            // upstream's own comparison allows by testing only the first byte.
            // This SDK compares the whole string, because it knows its own.
            const reported = std.mem.span(dst.zlibVersion());
            if (!std.mem.startsWith(u8, reported, expected)) {
                // The two strings go to the diagnostic stream rather than into
                // the returned text: `validate` has no allocator and the loader
                // reports whatever string it is given.
                std.debug.print(
                    "zlib: provider reports zlibVersion \"{s}\", this SDK's " ++
                        "src/zlib.h:44 declares ZLIB_VERSION \"{s}\"; a 1.3.2 " ++
                        "consumer cannot use that provider's ABI\n",
                    .{ reported, expected },
                );
                return "this provider reports a zlib version that is not the " ++
                    "one this SDK's headers describe";
            }

            // Check 2: the compile-time configuration.
            //
            // Only the two macros `zlibCompileFlags` actually reports a bit for
            // can be answered from its answer; the module comment says where
            // `Z_PREFIX`, `ZLIB_CONST` and the 1.2.x `GZIP_CONST` are caught,
            // or why they cannot be caught here at all.
            const flags: u32 = @truncate(@as(u64, @bitCast(dst.zlibCompileFlags())));
            if ((flags & flag_debug) != 0) {
                std.debug.print(
                    "zlib: provider reports compile flag bit 8 (ZLIB_DEBUG, " ++
                        "src/zlib.h:1226) set; this SDK builds no debug provider " ++
                        "and will not link against one\n",
                    .{},
                );
                return "this provider is a ZLIB_DEBUG build, which this SDK " ++
                    "does not provide and does not support";
            }
            if ((flags & flag_winapi) != 0) {
                std.debug.print(
                    "zlib: provider reports compile flag bit 10 (ZLIB_WINAPI, " ++
                        "src/zlib.h:1228) set; src/zconf.h:367 then declares every " ++
                        "exported function WINAPI, so its calling convention is " ++
                        "not the one these headers describe\n",
                    .{},
                );
                return "this provider exports WINAPI-declared entry points, " ++
                    "which is a different calling convention under the same " ++
                    "symbol names";
            }

            // Check 3: a real one-shot round trip through the provider.
            //
            // `compress2` (`src/zlib.h:1288`) and `uncompress2` (`:1335`) are
            // the shortest path from nothing to evidence: both allocate through
            // the provider (`src/compress.c:70-96` and `src/uncompr.c:39-52`
            // open and end a stream), both return `Z_OK` only on success
            // (`src/zlib.h:1295-1301` and `:1339-1348`), and `uncompress2` also
            // verifies the stream's Adler-32 (`src/uncompr.c:24-35`). A
            // provider whose sizes, stream layout or allocator disagree fails
            // here rather than silently later.
            //
            // The two length arguments are written through pointers the caller
            // supplies (`src/zlib.h:1288-1289`), so both buffers are owned by
            // this frame and both lengths are re-read after the call rather
            // than assumed.
            const bound = dst.compressBound(probe_input_len);
            if (bound == 0 or bound > probe_output_max) {
                std.debug.print(
                    "zlib: provider answers compressBound({d}) = {d}, outside " ++
                        "1..{d}\n",
                    .{ probe_input_len, bound, probe_output_max },
                );
                return "compressBound answered a value this loader will not " ++
                    "size a buffer from";
            }

            var compressed: [probe_output_max]u8 = undefined;
            var compressed_len: c_ulong = @intCast(bound);
            const wrote = dst.compress2(
                &compressed,
                &compressed_len,
                probe_input,
                @intCast(probe_input_len),
                6,
            );
            if (wrote != 0) {
                std.debug.print(
                    "zlib: compress2 through the provider returned {d}\n",
                    .{wrote},
                );
                return "compress2 did not return Z_OK through this provider";
            }
            if (compressed_len == 0 or compressed_len > bound) {
                std.debug.print(
                    "zlib: compress2 wrote {d} bytes into a bound of {d}\n",
                    .{ compressed_len, bound },
                );
                return "compress2 wrote past the bound it was given";
            }

            // Filled with a byte no part of the payload holds, so a provider
            // that reported success without writing is caught rather than
            // compared against its own leftovers.
            var plain: [probe_input_len]u8 = @splat(0xa5);
            var plain_len: c_ulong = @intCast(probe_input_len);
            const read = dst.uncompress2(&plain, &plain_len, &compressed, compressed_len);
            if (read != 0) {
                std.debug.print(
                    "zlib: uncompress2 through the provider returned {d}\n",
                    .{read},
                );
                return "uncompress2 did not return Z_OK through this provider";
            }
            if (plain_len != probe_input_len) {
                return "uncompress2 reported a different length than the " ++
                    "payload it was given";
            }
            if (!std.mem.eql(u8, &plain, probe_input)) {
                return "a compress2/uncompress2 round trip through this " ++
                    "provider did not return the bytes that went in";
            }

            // Check 4: the bound is a bound.
            //
            // `src/zlib.h:1298-1306` promises `compressBound` is an upper bound
            // on the compressed size of `sourceLen` bytes. A provider whose
            // answer is smaller than the input is answering something else -
            // an `int` where a `uLong` was expected would do exactly this - and
            // a caller that trusted it would overflow.
            const small_bound = dst.compressBound(64);
            if (small_bound < 64) {
                std.debug.print(
                    "zlib: provider answers compressBound(64) = {d}, which is " ++
                        "smaller than its input; src/zlib.h:1298-1306 documents " ++
                        "this as an upper bound\n",
                    .{small_bound},
                );
                return "compressBound answered less than the length it was " ++
                    "given, so it is not the upper bound these headers describe";
            }

            return null;
        }
    };
}