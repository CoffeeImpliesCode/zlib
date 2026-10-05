// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.

//! Zig facade over the zlib 1.3.2 C implementation.
//!
//! No part of the format is reimplemented here. Every value that comes back out
//! of this module was produced by the C under `src/`, reached through
//! `pub const c`, the module the translation step produces from
//! `zig/translate.h`. What the facade adds is the part a C header cannot
//! express: a stream that owns itself and says what ending it means, a status
//! code cut down to the failures a caller can act on, slices instead of
//! caller-managed `uLongf *` length variables, and one `Gzip` that owns a
//! `gzFile` rather than a raw pointer that can be closed twice.
//!
//! ## Import routes
//!
//! One Zig route is published: `dep.module("zlib")` in the dependent's
//! `build.zig`, which is `@import("zlib")` in source. The translated headers are
//! `c` on that same module and are not published as a module of their own, so
//! the declarations and the library that satisfy them arrive through one route.
//! A C consumer takes the installed headers and the installed library instead;
//! `README.zig.md` names that layout.
//!
//! ```zig
//! const zlib = @import("zlib");
//! const std = @import("std");
//!
//! pub fn main() !void {
//!     var out: [512]u8 = undefined;
//!     const n = try zlib.compress2(&out, "hello hello hello", .{});
//!     var back: [64]u8 = undefined;
//!     const m = try zlib.uncompress(&back, out[0..n]);
//!     std.debug.print("{s}\n", .{back[0..m]});
//! }
//! ```
//!
//! ## Allocation: this module owns nothing on the heap, and libc owns the rest
//!
//! This module allocates nothing and wraps nothing on a Zig heap. `Deflater`,
//! `Inflater` and `Gzip` are a `z_stream` and a `gzFile` respectively.
//!
//! The memory behind them is upstream's, and it is worth stating plainly.
//! `zalloc` and `zfree` are two fields in `z_stream` (`src/zlib.h:103-104`)
//! that this module leaves null, and `src/zconf.h:216` says `Z_NULL` is "for
//! initializing zalloc, zfree, opaque". Left null, `deflateInit2` and
//! `inflateInit2` call libc's `malloc`, `realloc` and `free` directly, through
//! `zcalloc` and `zcfree` in `src/zutil.c`, and `Gzip` does the same for its
//! internal state. `compress2` and `uncompress2` do too: `src/compress.c` and
//! `src/uncompr.c:29-82` each open and end a stream, and neither takes an
//! allocator argument.
//!
//! **So memory crosses into libc's allocator with no Zig allocator in the
//! path, and `std.testing.allocator` cannot be a leak oracle for any of it.** No
//! test in this package claims it is. What a test can check is the ownership
//! transition this module owns: that `deinit` ends the stream, that a second
//! `deinit` on the same variable is not a second `deflateEnd`, and that one
//! stream ending does not disturb another.
//!
//! Every byte this module hands back that is not the caller's own buffer is a
//! **borrow**, and each doc comment says so at the place it returns one. Nothing
//! here copies and nothing here frees.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which at
//! comptime.
//!
//! *Linked* is the default. The C library is linked, `c` is the translation of
//! `zlib.h` and `zconf.h`, and every call below is a direct call with no table
//! and no check.
//!
//! *Runtime-loaded* is opt-in (`-Druntime`). The library is not linked; `c` is a
//! dispatch generated from the same translation step's output, and the entry
//! points those two headers declare are resolved through the platform loader
//! when the caller calls
//!
//! ```zig
//! try zlib.load(.{ .path = "/usr/lib/libz.so.1.3.2" });
//! ```
//!
//! before using anything else. A call into a module that has not loaded stops the
//! program with a message naming the function, in every optimization mode. That
//! is a programming error rather than a recoverable condition: the table does not
//! exist yet and there is no partial state to fall back on. The load itself
//! reports a missing file, a provider that does not export what the headers
//! declare, a request that cannot be honoured because a different provider
//! already won, or a reentrant call, as errors rather than as a different
//! library being loaded instead.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other,
//! the module has no unload and no reset, and it keeps the handle and its own
//! copy of the request to the end of the process.
//!
//! `runtime/library.zig` states what a provider must be, including the zlib
//! 1.3.2 external ABI this SDK supports, the four checks it runs before
//! publishing a table, and the three configurations that are caught earlier or
//! not at all.
//!
//! ## Status codes, and the one error set
//!
//! Upstream returns an `int` whose negative values are failures and whose
//! positive values are events (`src/zlib.h:290-292`). This module turns that into
//! exactly two shapes:
//!
//!   * `Status` is the full enumeration, all nine codes of `src/zlib.h:181-189`,
//!     so nothing the C can say is unrepresentable.
//!   * `Error` is the one error set this module has. Seven of its members are
//!     zlib status codes, cut at exactly the seven this package's own code turns
//!     into a Zig error, each cited on `Status`. `Z_OK` and `Z_STREAM_END` are not
//!     members because neither is a failure: one is success and the other is how
//!     a stream ends normally.
//!
//! The remaining members are this module's own, and they are here because the C
//! says something with no status code at all. They are named as such:
//!
//!   * `UnknownStatus` - a value arrived that this SDK does not name. It exists
//!     so that no raw `c_int` is ever clamped into a neighbouring code.
//!   * `OpenFailed` - `gzopen` returned null. `src/zlib.h:1380-1390` says that
//!     covers both "the file could not be opened" and "the memory for the
//!     `gzFile` state could not be allocated", and zlib does not tell the two
//!     apart. This module does not invent a distinction either.
//!   * `EndOfInput` - `gzread` read zero bytes. `src/zlib.h:1490-1493` calls
//!     that end of file, and a caller that cannot tell it from "no progress was
//!     possible" needs it named rather than left as a zero.
//!   * `NotWritable` - `gzwrite` wrote zero bytes for a non-empty request.
//!     `src/zlib.h:1519-1522` says a zero return there is an error or `len` was
//!     0, and a non-empty request that produced nothing is the first.
//!
//! `statusOf` is the one funnel from a raw `c_int` to a `Status`; `codeOrError`
//! is the one place that decides "is this a failure". Neither is duplicated
//! anywhere else in this file.
//!
//! ## Slices in, lengths out
//!
//! `compress2`, `uncompress` and `uncompress2` write through a length pointer the
//! caller supplies (`src/zlib.h:1288-1289`, `:1315-1316`, `:1335-1336`), and on
//! input that pointer is the capacity. A Zig slice carries the length, so these
//! take `[]u8` for the destination and return the count written; the caller never
//! owns a `uLongf` variable that can disagree with the buffer it describes.
//!
//! `uncompress2` differs from `uncompress` in exactly one documented way:
//! `sourceLen` is a **pointer**, and on return it is the number of source bytes
//! consumed (`src/zlib.h:1339-1343`). So `uncompress2` here takes the source by
//! pointer and advances it, which is what lets a caller read several concatenated
//! zlib streams out of one buffer - and `src/gzread.c:1466-1471` is upstream
//! making the same point about concatenated gzip members.
//!
//! Note what is *not* in that difference: `src/uncompr.c:76` writes the amount of
//! data *produced* through `destLen`, not the size that would have been required.
//! So a short buffer does not learn how big to retry from this call; the error is
//! `error.BufError` and nothing more.
//!
//! ## Streams are not safe to share
//!
//! A `z_stream` is plain mutable state with no locking, so a `Deflater` or an
//! `Inflater` belongs to one thread at a time. Nothing else in this module is
//! shared, because nothing else is stateful except the loader's own table, which
//! the loader core synchronises.
//!
//! `deflateCopy` and `inflateCopy` are the one sanctioned way to have two streams
//! at once, and each is exposed as a method that writes into a destination this
//! module did not initialise - which is what upstream requires. See
//! `Inflater.copyFrom`.

const std = @import("std");

/// The translated `zlib.h` and `zconf.h`, i.e. upstream's ABI exactly as
/// published.
///
/// This is the escape hatch for a declaration the facade does not name
/// (`deflateTune`, `deflatePrime`, `inflatePrime`, `inflateReset2`,
/// `inflateSetDictionary`, `inflateBack`, the `*_z` length-taking variants, the
/// `64`-suffixed large-file variants, `gzprintf` and its `va_list`) and for
/// `z_stream` itself. It is the same module the facade calls, on the same
/// library, so importing the facade is all a dependent needs to reach it; it is
/// not published under a name of its own.
///
/// The declarations are for whichever headers this build selected: bundled mode
/// translates `src/zlib.h` and the *generated* `zconf.h` for the target, system
/// mode the installed ones. A caller that reaches past the facade gets upstream
/// behaviour and inherits every obligation upstream declares.
///
/// ## The macros, and what they become
///
/// zlib's convenience operations are C macros, and the translation step carries
/// each one into `c` as `pub inline fn NAME(params: anytype) T` whose body is
/// the macro's own expansion. Three of them decide how this module calls the C:
///
///   * `deflateInit2` is `deflateInit2_((strm), ..., ZLIB_VERSION,
///     (int)sizeof(z_stream))` (`src/zlib.h:1930-1932`), and `inflateInit2` is
///     the same with its own arguments (`:1935-1937`). **That is why
///     `Deflater.init` and `Inflater.init` call the `_` forms:** the macro is
///     what supplies `ZLIB_VERSION` and `sizeof(z_stream)`, and hand-writing
///     that pair here would be a second place where the version could be
///     restated wrongly. The two functions pass the same values the macro would.
///   * `gzgetc(g)` is `((g)->have ? ((g)->have--, (g)->pos++, *((g)->next)++) :
///     (gzgetc)(g))` (`src/zlib.h:1968-1971`), a one-byte pushback buffer read
///     through the three fields of the "abbreviated" `struct gzFile_s` that
///     upstream itself describes at `:1959-1963` as elements that "can only be
///     used by the `gzgetc` macro". `Gzip.getByte` calls the `gzgetc_` function
///     underneath instead, which is the same function the macro falls back to.
///   * `zlib_version` is `zlibVersion()` (`src/zlib.h:218`), kept for
///     compatibility with versions before 1.0.2. `zlibVersion()` is what this
///     module calls.
///
/// Which names take that shape is the translation's business rather than a
/// promise this module makes: one it cannot lower at all is a `pub const` whose
/// value is `@compileError`. None of the three above is expected to be of that
/// kind, and none is routed at run time - only `extern` declarations are, so a
/// wrapper is copied into a runtime-loaded dispatch and rewritten to call the
/// routed function it expands to. A provider exports nothing for any of them.
pub const c = @import("c");

/// The loader core, which is where a linked build's two public types come from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the dispatch carries its own copy of the same declarations, and this module
/// is never referenced, so it is never resolved and never compiled. Either way
/// there is exactly one `LoadSource` and one `LoadError` in a build, which is
/// what keeps them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the C library is linked and `c` is the
/// translation of the two public headers. True when the build generated a
/// dispatch that resolves the same symbols through the platform loader, in which
/// case `load` is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit fallback
/// of any kind; a request that cannot be honoured is an error, not a different
/// library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside the
/// loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then use
/// this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use. A
/// failed attempt publishes nothing and can be retried explicitly, by calling
/// this again: there is no automatic retry and no implicit second source.
///
/// It keeps the process handle and its own copy of the request to the end of the
/// process. There is no unload and no reset, because the table is process-global
/// state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports both
/// configurations can tell the two apart at comptime instead of meeting this at
/// run time.
pub fn load(source: LoadSource) LoadError!void {
    // `c.load` exists only in a runtime-loading build. The condition is known at
    // comptime, so the branch this build does not take is never analyzed and
    // never names it.
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "zlib: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with runtime " ++
            "loading configured, or do not call load.",
        .{},
    );
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// `src/zlib.h`, embedded so that the version below is read out of the header
/// this package compiled rather than restated beside it.
///
/// A second copy of `1.3.2` in a Zig file is a second fact that can drift from
/// `src/zlib.h:44` and from `build.zig.zon .version` without anything noticing.
///
/// The bytes arrive through the `zlib_header` import rather than through an
/// `@embedFile` of a relative path: this module's package is `zig/`, and the
/// compiler answers `embed of file outside package path` for
/// `@embedFile("../src/zlib.h")`. `build.zig` copies the header beside a
/// generated root - see `graph.addHeaderImport` - so the bytes embedded are
/// still the ones `UPSTREAM.sha256` covers, and the header travels to a
/// dependent because `src` is in `build.zig.zon .paths`.
const zlib_header = @import("zlib_header").bytes;

/// Capacity of the array `headerString` returns, and short enough that it is
/// one cache line. A `ZLIB_*` string longer than this is a `@compileError`
/// rather than a silent truncation.
const version_string_max = 32;

/// The bytes between the first pair of quotes after `#define <name> "`, as a
/// sentinel-terminated array.
///
/// An array rather than a `[:0]const u8`, and the caller below takes `&` of it,
/// because the other two shapes do not survive comptime. A slice pointing into
/// `zlib_header` cannot be sentinel-terminated at all: the only terminator that
/// array has is its last byte, and the bytes between the quotes are followed by
/// the closing quote. And a slice pointing into a *comptime* local is rejected
/// outright - `global variable contains reference to comptime var`. A
/// `*const [N:0]u8` is exactly a `[:0]const u8`, and `&`-of-a-container-scope
/// `const` is a pointer to a global, not to a local.
///
/// A `@compileError` when the macro is not there: that is a header this module
/// was written against being absent, and it must be a configure-time failure
/// rather than a null a caller has to check.
fn headerString(comptime name: []const u8) [version_string_max:0]u8 {
    comptime var needle: [80]u8 = undefined;
    const prefix = "#define ";
    @memcpy(needle[0..prefix.len], prefix);
    @memcpy(needle[prefix.len..][0..name.len], name);
    needle[prefix.len + name.len] = ' ';
    needle[prefix.len + name.len + 1] = '"';
    const at = comptime std.mem.indexOf(
        u8,
        zlib_header,
        needle[0 .. prefix.len + name.len + 2],
    ) orelse @compileError("zig/root.zig: src/zlib.h has no " ++ name ++ " string definition");
    const body = at + prefix.len + name.len + 2;
    const end = comptime std.mem.indexOfScalarPos(u8, zlib_header, body, '"') orelse
        @compileError("zig/root.zig: unterminated " ++ name ++ " in src/zlib.h");
    const found = zlib_header[body..end];
    if (found.len >= version_string_max) @compileError(
        "zig/root.zig: " ++ name ++ " does not fit in version_string_max",
    );
    var out: [version_string_max:0]u8 = .{0} ** version_string_max;
    @memcpy(out[0..found.len], found);
    return out;
}

/// The value of `#define <name> <value>`, for the two shapes zlib uses:
/// a decimal integer, possibly parenthesised and negative, or `0x`-prefixed hex.
///
/// Two shapes because `src/zlib.h` uses both: `ZLIB_VERNUM 0x1320` (`:45`) is
/// hex and `ZLIB_VER_MAJOR 1` (`:46`) is decimal. Parsing them differently rather
/// than deriving one from the other is what keeps `version_num` a value read out
/// of the header instead of a re-encoding of its layout.
fn headerInt(comptime name: []const u8) u64 {
    comptime var needle: [80]u8 = undefined;
    const prefix = "#define ";
    @memcpy(needle[0..prefix.len], prefix);
    @memcpy(needle[prefix.len..][0..name.len], name);
    const full = needle[0 .. prefix.len + name.len];
    const at = comptime std.mem.indexOf(u8, zlib_header, full) orelse
        @compileError("zig/root.zig: src/zlib.h has no " ++ name);
    comptime var i = at + full.len;
    while (i < zlib_header.len and
        (zlib_header[i] == ' ' or zlib_header[i] == '\t')) : (i += 1)
    {}
    comptime var negative = false;
    if (i < zlib_header.len and zlib_header[i] == '(') {
        i += 1;
    }
    while (i < zlib_header.len and zlib_header[i] == ' ') : (i += 1) {}
    if (i < zlib_header.len and zlib_header[i] == '-') {
        negative = true;
        i += 1;
    }
    comptime var base: u8 = 10;
    if (i + 1 < zlib_header.len and zlib_header[i] == '0' and
        (zlib_header[i + 1] == 'x' or zlib_header[i + 1] == 'X'))
    {
        base = 16;
        i += 2;
    }
    comptime var value: u64 = 0;
    comptime var digits: usize = 0;
    while (i < zlib_header.len) : (i += 1) {
        const ch = zlib_header[i];
        const d: u64 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => break,
        };
        if (d >= base) break;
        value = value * base + d;
        digits += 1;
    }
    if (digits == 0) @compileError("zig/root.zig: " ++ name ++ " in src/zlib.h has no value");
    return if (negative) (0 -% value) else value;
}

/// The release string this SDK's headers declare, `src/zlib.h:44`
/// (`#define ZLIB_VERSION "1.3.2"`).
///
/// Read out of the embedded header rather than written here, so `version`,
/// `version_num`, `zlibVersion` and `build.zig.zon .version` are one fact.
const version_array = headerString("ZLIB_VERSION");
/// The bytes of `array` up to its first NUL.
///
/// `&version_array` on its own would be a `[:0]const u8` of the whole padded
/// array, so every caller would see 32 bytes rather than 5.
fn trimmed(comptime array: anytype) [:0]const u8 {
    const at = comptime std.mem.indexOfScalar(u8, &array, 0) orelse unreachable;
    return array[0..at :0];
}
pub const version: [:0]const u8 = trimmed(version_array);

/// The packed release number, `src/zlib.h:45` (`#define ZLIB_VERNUM 0x1320`).
///
/// Read as the hex constant it is written as, rather than re-encoded from the
/// four components - a re-encoding would be a second statement about the layout
/// and could disagree with it.
pub const version_num: u32 = @intCast(headerInt("ZLIB_VERNUM"));

/// What `zlibVersion()` returns: the release the *provider* was compiled with.
///
/// Read through the escape hatch rather than quoted, so in a runtime-loaded
/// build this line is a statement about the provider rather than about a
/// constant compiled into the program. The returned slice is a NUL-terminated
/// string in the library's own storage - `src/zutil.c:27-29` returns
/// `ZLIB_VERSION`, a string literal - so it is a borrow that never expires and
/// never needs freeing.
pub fn zlibVersion() [:0]const u8 {
    return std.mem.span(c.zlibVersion());
}

/// The provider's compile-time configuration, as `zlibCompileFlags` reports it.
///
/// `src/zlib.h:1217-1253` is the documentation and the bit map; `src/zutil.c:31`
/// builds the value. Bits 1.0 and 3.2 are the sizes of `uInt` and `uLong` two
/// bits each, 5.4 and 7.6 are `voidpf` and `z_off_t`, and the named bits above
/// that are the configuration switches. The two this SDK refuses are bit 8
/// (`ZLIB_DEBUG`, `src/zlib.h:1226`) and bit 10 (`ZLIB_WINAPI`,
/// `src/zlib.h:1228`); `runtime/library.zig` rejects a provider that reports
/// either.
pub fn zlibCompileFlags() u32 {
    // `uLong` is `c_ulong`, and its width is the target's: 64 bits where LP64
    // applies and 32 on `x86_64-windows-gnu` (`src/zconf.h:340-346`). A
    // `@bitCast` through a `u64` is only legal when the two agree, so the
    // narrowing is written as the `@truncate` it actually is.
    const raw: c_ulong = c.zlibCompileFlags();
    return @truncate(raw);
}

/// Bit 8 of `zlibCompileFlags`: the provider is a `ZLIB_DEBUG` build
/// (`src/zlib.h:1226`).
pub const flag_debug: u32 = 1 << 8;

/// Bit 10 of `zlibCompileFlags`: the provider's exported entry points are
/// declared `WINAPI` (`src/zlib.h:1228`).
pub const flag_winapi: u32 = 1 << 10;

/// Every status code `src/zlib.h:181-189` defines, and no others.
///
/// The negative values are failures and the positive values are events
/// (`src/zlib.h:290-292`). `errno` is in the set because the `gz*` functions do
/// return it - `src/gzread.c:41`, `src/gzwrite.c:84` and `src/gzread.c:667` all
/// hand it back - and so it belongs in any set cut at what a `Gzip` checks.
pub const Status = enum(c_int) {
    /// `Z_OK 0` (`src/zlib.h:181`). Success; not an error.
    ok = 0,
    /// `Z_STREAM_END 1` (`src/zlib.h:182`). The end of the stream; not an error.
    stream_end = 1,
    /// `Z_NEED_DICT 2` (`src/zlib.h:183`). A preset dictionary is needed.
    need_dict = 2,
    /// `Z_ERRNO (-1)` (`src/zlib.h:184`). A file error; consult `errno`.
    errno = -1,
    /// `Z_STREAM_ERROR (-2)` (`src/zlib.h:185`). The stream state was
    /// inconsistent, or a parameter was out of range.
    stream_error = -2,
    /// `Z_DATA_ERROR (-3)` (`src/zlib.h:186`). The input data is corrupt.
    data_error = -3,
    /// `Z_MEM_ERROR (-4)` (`src/zlib.h:187`). Not enough memory.
    mem_error = -4,
    /// `Z_BUF_ERROR (-5)` (`src/zlib.h:188`). No progress was possible.
    buf_error = -5,
    /// `Z_VERSION_ERROR (-6)` (`src/zlib.h:189`). The library and the headers
    /// disagree about the version.
    version_error = -6,

    /// The Zig error this code becomes, or null when it is not a failure.
    ///
    /// `ok` and `stream_end` are null: one is success and the other is how a
    /// stream ends normally. `src/zlib.h:331-335` is explicit that
    /// `Z_STREAM_END` is the answer a caller is waiting for rather than a failure
    /// to handle, and `src/zlib.h:467-470` says the same of `inflate`.
    ///
    /// A code outside this enumeration cannot reach this function: `statusOf`
    /// turns it into `error.UnknownStatus` before any wrapper gets this far.
    pub fn errorCode(self: Status) ?Error {
        return switch (self) {
            .ok, .stream_end => null,
            .need_dict => Error.NeedDict,
            .errno => Error.Errno,
            .stream_error => Error.StreamError,
            .data_error => Error.DataError,
            .mem_error => Error.MemError,
            .buf_error => Error.BufError,
            .version_error => Error.VersionError,
        };
    }
};

/// The one error set this module has.
///
/// Seven members are zlib status codes, each cited on `Status`, and each present
/// because this package's own code checks it. Five members are this module's,
/// and they are listed as such so a caller can tell at a glance which failures
/// are zlib's and which are this SDK's.
pub const Error = error{
    // --- zlib status codes, `src/zlib.h:181-189` ---
    /// `Z_NEED_DICT` (`src/zlib.h:183`): the stream needs a preset dictionary
    /// before it can continue. `src/inflate.c` returns this when the stream
    /// declared one it cannot have.
    NeedDict,
    /// `Z_ERRNO` (`src/zlib.h:184`): a file error. The `gz*` functions return
    /// this on a failed `read`, `write` or `close`, and upstream's own note at
    /// `src/zlib.h:1780` is that "the application may consult errno to get the
    /// exact error".
    Errno,
    /// `Z_STREAM_ERROR` (`src/zlib.h:185`): the stream state was inconsistent,
    /// or a parameter was out of its documented range.
    StreamError,
    /// `Z_DATA_ERROR` (`src/zlib.h:186`): the input is corrupt. A decompressor
    /// that has already produced output does not clear it - `src/uncompr.c:78-81`
    /// returns the error and leaves the buffer as it was - so a caller reading
    /// `error.DataError` may hold partial output.
    DataError,
    /// `Z_MEM_ERROR` (`src/zlib.h:187`): not enough memory.
    MemError,
    /// `Z_BUF_ERROR` (`src/zlib.h:188`): no progress was possible. For
    /// `compress2` it means the output slice was too small and nothing was
    /// written (`src/zlib.h:1295-1301`); for `inflate` it can mean a truncated
    /// stream (`src/zlib.h:515-518`).
    BufError,
    /// `Z_VERSION_ERROR` (`src/zlib.h:189`): the library and the headers
    /// disagree about the version.
    VersionError,

    // --- this module's own, where the C says something with no status code ---
    /// A status value this SDK does not name. Produced only by `statusOf`, so no
    /// raw `c_int` is ever clamped into a neighbouring code.
    UnknownStatus,
    /// `gzopen` returned null. `src/zlib.h:1380-1390` says that covers both a
    /// file that could not be opened and a `gzFile` state that could not be
    /// allocated, and zlib does not tell the two apart.
    OpenFailed,
    /// `gzread` read zero bytes, which `src/zlib.h:1490-1493` calls end of file.
    EndOfInput,
    /// `gzwrite` wrote nothing for a non-empty request, which
    /// `src/zlib.h:1519-1522` says is an error or a zero length; this is the
    /// first, with the second ruled out by the caller passing a non-empty slice.
    NotWritable,
};

/// Read a raw `c_int` from zlib as a `Status`.
///
/// The one place an integer from the C becomes anything else. A value outside
/// `src/zlib.h:181-189` becomes `error.UnknownStatus` rather than being clamped
/// into a neighbouring code, and the numeric value is still available from
/// `zError`.
pub fn statusOf(code: c_int) Error!Status {
    // `std.meta.intToEnum` is gone in this compiler, and
    // `@typeInfo(T).@"enum"` carries no `min`/`max` either, so the tag set is
    // walked at comptime. That is what keeps the promise in the doc comment
    // above: a code outside `src/zlib.h:181-189` becomes `error.UnknownStatus`
    // rather than a value clamped into a neighbouring tag, which is all that
    // `@enumFromInt` alone would do - and silently.
    comptime var lowest: c_int = undefined;
    comptime var highest: c_int = undefined;
    comptime var first = true;
    inline for (@typeInfo(Status).@"enum".fields) |field| {
        const value: c_int = field.value;
        if (first or value < lowest) lowest = value;
        if (first or value > highest) highest = value;
        first = false;
    }
    if (code < lowest or code > highest) return Error.UnknownStatus;
    const status: Status = @enumFromInt(code);
    if (@intFromEnum(status) != code) return Error.UnknownStatus;
    return status;
}

/// Upstream's own text for a status code (`src/zlib.h:2033`, `src/zutil.c:139-141`).
///
/// `zError` indexes `z_errmsg` (`src/zutil.c:13-24`) at `2 - err`, so it answers
/// for every code in `-6..=2` and gives `src/zutil.c:23`'s empty string for a
/// value in range but not in the table. Outside that range upstream's indexing is
/// out of bounds, so the value is clamped to the documented span first.
///
/// The returned slice is a borrow into the library's own static table and is
/// never freed.
pub fn zError(code: c_int) [:0]const u8 {
    const clamped = std.math.clamp(code, @as(c_int, -6), @as(c_int, 2));
    return std.mem.span(c.zError(clamped));
}

/// Turn a raw status into a `Status` or an `Error`.
///
/// Every wrapper that only needs "did it work" reaches the C through here, so
/// there is exactly one place where "is this a failure" is decided.
fn codeOrError(code: c_int) Error!void {
    const status = try statusOf(code);
    if (status.errorCode()) |err| return err;
}

/// How a stream should be flushed.
///
/// The values are `src/zlib.h:172-178` verbatim, named so a caller never has to
/// pass a bare `int` where the header wanted one of seven.
pub const Flush = enum(c_int) {
    /// `Z_NO_FLUSH 0` (`src/zlib.h:172`).
    no_flush = 0,
    /// `Z_PARTIAL_FLUSH 1` (`src/zlib.h:173`).
    partial_flush = 1,
    /// `Z_SYNC_FLUSH 2` (`src/zlib.h:174`).
    sync_flush = 2,
    /// `Z_FULL_FLUSH 3` (`src/zlib.h:175`).
    full_flush = 3,
    /// `Z_FINISH 4` (`src/zlib.h:176`).
    finish = 4,
    /// `Z_BLOCK 5` (`src/zlib.h:177`).
    block = 5,
    /// `Z_TREES 6` (`src/zlib.h:178`).
    trees = 6,
};

/// The compression level.
///
/// `src/zlib.h:194-197` names three levels and one non-level:
/// `Z_NO_COMPRESSION 0`, `Z_BEST_SPEED 1`, `Z_BEST_COMPRESSION 9` and
/// `Z_DEFAULT_COMPRESSION (-1)`, which means "use the library default". The two
/// to eight in between are accepted and documented at `src/zlib.h:248-253`, so
/// they are in the set rather than rejected.
pub const Level = enum(c_int) {
    /// `Z_NO_COMPRESSION 0` (`src/zlib.h:194`).
    no_compression = 0,
    /// `Z_BEST_SPEED 1` (`src/zlib.h:195`).
    best_speed = 1,
    /// `Z_BEST_COMPRESSION 9` (`src/zlib.h:196`).
    best_compression = 9,
    /// `Z_DEFAULT_COMPRESSION (-1)` (`src/zlib.h:197`): the library's own
    /// default, which for `deflate` is level 6.
    default_compression = -1,
    /// 2 through 8, which upstream accepts with a different ratio and speed
    /// trade-off and this SDK does not reject.
    _,
};

/// The compression strategy, `src/zlib.h:200-204`.
pub const Strategy = enum(c_int) {
    /// `Z_DEFAULT_STRATEGY 0` (`src/zlib.h:204`).
    default = 0,
    /// `Z_FILTERED 1` (`src/zlib.h:200`): for data with a small alphabet.
    filtered = 1,
    /// `Z_HUFFMAN_ONLY 2` (`src/zlib.h:201`): no LZ77 matching.
    huffman_only = 2,
    /// `Z_RLE 3` (`src/zlib.h:202`): run-length only.
    rle = 3,
    /// `Z_FIXED 4` (`src/zlib.h:203`): the fixed Huffman codes of RFC 1951
    /// §3.2.6 (`src/doc/rfc1951.txt:655-681`).
    fixed = 4,
};

/// Which of the three container formats a stream reads or writes.
///
/// The distinction is `windowBits`, and it is not cosmetic: the same deflate
/// stream is framed differently in each, and reading one with the wrong value is
/// a `Z_DATA_ERROR` rather than an auto-detect.
pub const Format = enum {
    /// A bare deflate stream, no header and no trailer: `windowBits` is negative.
    /// `src/zlib.h:236-241` requires -8 to -15.
    raw,
    /// The zlib wrapper of RFC 1950: a two-byte `CMF`/`FLG` header and a
    /// four-byte Adler-32 trailer (`src/doc/rfc1950.txt:210-240`).
    zlib,
    /// The gzip wrapper of RFC 1952: a ten-byte header, optional fields, and a
    /// CRC-32 plus ISIZE trailer (`src/doc/rfc1952.txt:243-277`).
    /// `windowBits` is 8 to 15 **plus 16** (`src/zlib.h:246`), which is how
    /// `inflate` is told to read a gzip stream rather than a zlib one.
    gzip,

    /// The `windowBits` value for a 32K window, which is the maximum in all
    /// three cases: `src/zconf.h:274-283` gives `MAX_WBITS` as 15, and
    /// `src/zlib.h:236-241` describes 8 to 15 as the accepted range for the
    /// wrapped formats.
    pub fn windowBits(self: Format) c_int {
        return switch (self) {
            .raw => -15,
            .zlib => 15,
            .gzip => 31,
        };
    }
};

/// What one `deflate` or `inflate` call moved.
///
/// Upstream reports progress through four fields of the stream - `avail_in`,
/// `avail_out`, `total_in` and `total_out` (`src/zlib.h:91-97`) - and reading
/// them is arithmetic on the two capacities. This is that arithmetic, once.
pub const Progress = struct {
    /// Input bytes taken from the slice that was passed.
    consumed: usize,
    /// Output bytes written into the slice that was passed.
    produced: usize,
    /// The code the call returned. `Z_OK` and `Z_STREAM_END` are the two
    /// non-failures a caller sees here.
    status: Status,
};

/// What `deflate` has produced but not yet flushed, and how much of the
/// compressor's own state is in use.
///
/// `deflatePending` (`src/zlib.h:786`, documented at `:775-785`) writes two
/// values through caller pointers: the number of bytes pending, and the number
/// of bits pending in the last of them. `deflateUsed` (`src/zlib.h:804`,
/// documented at `:790-802`) writes a third.
pub const Pending = struct {
    /// Bytes produced by `deflate` and not yet flushed.
    bytes: usize,
    /// Bits pending in the last byte, 0 to 7. `src/zlib.h:783-785` says the
    /// value is 0 when the pending buffer is empty, so the clamp below never
    /// changes a value upstream meant.
    bits: u8,
    /// Bytes of the compressor's own output state in use.
    used: usize,
};

/// The options `Deflater.init` takes.
///
/// Named once here and shared with `compress2`, so the two cannot drift apart
/// about what a default means.
pub const CompressOptions = struct {
    /// `src/zlib.h:194-197`; defaults to `Z_DEFAULT_COMPRESSION`.
    level: Level = .default_compression,
    /// `src/zlib.h:200-204`; defaults to `Z_DEFAULT_STRATEGY`.
    strategy: Strategy = .default,
    /// The window size, 8 to 15, from `src/zlib.h:487-505`. Defaults to 15, the
    /// 32K window, which is `MAX_WBITS` (`src/zconf.h:274-283`).
    window_bits: u8 = 15,
    /// The internal buffer size, 1 to `max_mem_level`, from `src/zconf.h:281-297`
    /// `DEF_MEM_LEVEL`. Defaults to 8, upstream's own `DEF_MEM_LEVEL`.
    mem_level: u8 = 8,
};

/// The `source` pointer `compress2` and `uncompress` are handed for an empty
/// input.
///
/// Upstream reads nothing from `source` when the length beside it is 0
/// (`src/zlib.h:1283-1285`), so a valid pointer to zero bytes is the whole
/// requirement. It is spelled out because `&.{}` will not do: there is no
/// element type there for the compiler to infer, and it answers `type 'u8' does
/// not support array initialization syntax`.
const no_source: [*c]const c.Bytef = @ptrCast("");

/// Compress `source` into `dest` in one call, as a zlib-wrapped stream.
///
/// `compress2` (`src/zlib.h:1288-1291`) writes through two caller pointers:
/// `destLen` is the capacity of `dest` on entry and the number of bytes written
/// on return. The slice carries the first and the return value carries the
/// second, so the caller never owns a `uLongf` variable that can disagree with
/// the buffer it describes. `source` is not modified and not retained.
///
/// Upstream's rule for the one failure a correct caller can provoke is at
/// `src/zlib.h:1295-1301`: `Z_BUF_ERROR` means `dest` was too small and
/// **nothing was written**, so `dest` is untouched and that is reported as
/// `error.BufError`. `error.MemError` and `error.StreamError` are the other two
/// the header lists.
pub fn compress2(dest: []u8, source: []const u8, options: CompressOptions) Error!usize {
    var dest_len: c_ulong = @intCast(dest.len);
    const code = c.compress2(
        dest.ptr,
        &dest_len,
        if (source.len == 0) no_source else source.ptr,
        @intCast(source.len),
        @intFromEnum(options.level),
    );
    try codeOrError(code);
    return @intCast(dest_len);
}

/// Compress `source` into `dest` in one call at the library's default level.
///
/// `compress` (`src/zlib.h:1271-1272`) is `compress2` with the level fixed, and
/// upstream's own note at `:1276-1280` is that a caller wanting a specific level
/// should use `compress2`. This exists because it is the name most existing code
/// calls; it is `compress2` with an empty options struct.
pub fn compress(dest: []u8, source: []const u8) Error!usize {
    return compress2(dest, source, .{});
}

/// Decompress a zlib-wrapped stream from `source` into `dest` in one call.
///
/// `uncompress` (`src/zlib.h:1315-1316`) writes the uncompressed length through
/// `destLen` on return, so the call answers "how many bytes did this produce".
///
/// On `error.BufError` upstream has written nothing, because the buffer was too
/// small to have started (`src/zlib.h:1325-1333`). On `error.DataError` the
/// buffer may hold partial output: `src/uncompr.c:78-81` returns the error
/// without clearing what `inflate` had already produced, and that is reported
/// rather than hidden.
pub fn uncompress(dest: []u8, source: []const u8) Error!usize {
    var dest_len: c_ulong = @intCast(dest.len);
    const code = c.uncompress(
        dest.ptr,
        &dest_len,
        if (source.len == 0) no_source else source.ptr,
        @intCast(source.len),
    );
    try codeOrError(code);
    return @intCast(dest_len);
}

/// Decompress one zlib-wrapped stream, advancing `source` past what it consumed.
///
/// `uncompress2` differs from `uncompress` in exactly one documented way:
/// `sourceLen` is a **pointer**, and on return it is the number of source bytes
/// consumed (`src/zlib.h:1339-1343`). That is what this signature expresses -
/// the source comes in by pointer and is advanced to the first unconsumed byte -
/// and it is what makes several concatenated zlib streams readable out of one
/// buffer, which is the same point `src/gzread.c:1466-1471` makes about
/// concatenated gzip members.
///
/// The bytes consumed are the stream *and* its trailer: `src/uncompr.c:75` sets
/// `*sourceLen` from what `inflate` left in `avail_in` after the stream ended, so
/// on success `source` points at whatever follows the stream.
///
/// What this does **not** do is report how large a short buffer should have been.
/// `src/uncompr.c:76` writes the amount *produced* through `destLen`, not the
/// amount required, so `error.BufError` is the whole of what a too-small buffer
/// learns. The way to learn the size is `compressBound`-style sizing on the way
/// in, or a streaming `Inflater`.
pub fn uncompress2(dest: []u8, source: *[]const u8) Error!usize {
    var dest_len: c_ulong = @intCast(dest.len);
    var source_len: c_ulong = @intCast(source.*.len);
    const code = c.uncompress2(
        dest.ptr,
        &dest_len,
        if (source.*.len == 0) no_source else source.*.ptr,
        &source_len,
    );
    source.* = source.*[@intCast(source_len)..];
    try codeOrError(code);
    return @intCast(dest_len);
}

/// An upper bound on the compressed size of `source_len` bytes.
///
/// `compressBound` (`src/zlib.h:1307`) is documented at `:1298-1306` as an
/// upper bound on the size of the compressed result, and the header is careful
/// about what makes it true: it holds for any `deflate` stream, *including* one
/// that chooses stored blocks, which is what makes it safe to size a buffer from
/// before compressing.
///
/// It cannot fail, so this does not return an error union.
pub fn compressBound(source_len: usize) usize {
    const bound: c_ulong = c.compressBound(@intCast(source_len));
    return @intCast(bound);
}

/// The Adler-32 of `bytes`, continuing from `adler`.
///
/// `adler32` (`src/zlib.h:1809`) is the running form: pass
/// `checksum.adler32_init` for a fresh checksum and the previous result to
/// continue. The algorithm is the one RFC 1950 §8.2 gives
/// (`src/doc/rfc1950.txt:479-490`), and its initial `s1 = 1` is what
/// `src/doc/rfc1950.txt:567-569`'s own sample code passes.
///
/// `src/adler32.c:7-11` is the reason the running form exists at all: it is an
/// incremental table-driven version of the recurrence, and the tables are static
/// and read-only.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    const value: c_ulong = c.adler32(@intCast(adler), bytes.ptr, @intCast(bytes.len));
    return @truncate(value);
}

/// Combine the Adler-32 of two consecutive byte runs.
///
/// `adler32_combine` (`src/zlib.h:1837`) answers the Adler-32 of
/// `bytes_1 ++ bytes_2` from the two checksums and the length of the second run,
/// without reading either. `len2` is the length of the run `adler2` covers, and
/// it is a required argument rather than something derivable: passing a different
/// length gives the checksum of a different concatenation, silently.
pub fn adler32_combine(adler1: u32, adler2: u32, len2: usize) u32 {
    const value: c_ulong = c.adler32_combine(
        @intCast(adler1),
        @intCast(adler2),
        @intCast(len2),
    );
    return @truncate(value);
}

/// The CRC-32 of `bytes`, continuing from `crc`.
///
/// `crc32` (`src/zlib.h:1848`) is the running form: pass
/// `checksum.crc32_init` for a fresh checksum. The construction is the one RFC
/// 1952 §8 points implementers at - `src/doc/rfc1952.txt:527` names the
/// `123456789` check value - and the trailer field that carries it in a gzip
/// member is `src/doc/rfc1952.txt:419-421`.
///
/// `src/crc32.c:12-18` records the one threading caveat that belongs with it: a
/// build with `DYNAMIC_CRC_TABLE` must call `get_crc_table()` once before other
/// threads use `crc32`, because the table's one-time initialisation is not
/// mutex-protected. This build never defines that macro - `src/Makefile.in:150-151`
/// shows the only way it is defined, and that is the assembly hook - so the
/// tables are built at compile time and there is nothing to initialise.
pub fn crc32(crc: u32, bytes: []const u8) u32 {
    const value: c_ulong = c.crc32(@intCast(crc), bytes.ptr, @intCast(bytes.len));
    return @truncate(value);
}

/// Combine the CRC-32 of two consecutive byte runs.
///
/// `crc32_combine` (`src/zlib.h:1874`) answers the CRC-32 of
/// `bytes_1 ++ bytes_2` from the two checksums and the length of the second run.
/// `len2` is that length, with the same silence-if-wrong property as
/// `adler32_combine`'s.
pub fn crc32_combine(crc1: u32, crc2: u32, len2: usize) u32 {
    const value: c_ulong = c.crc32_combine(@intCast(crc1), @intCast(crc2), @intCast(len2));
    return @truncate(value);
}

/// Precompute the operator `crc32_combine_op` needs for a second run of `len2`
/// bytes.
///
/// `crc32_combine_gen` (`src/zlib.h:1884`, `src/crc32.c:964-966`) is the
/// expensive half of combining: `src/crc32.c:954-957` shows it is a modular
/// exponentiation, `x2nmodp(len2, 3)`, and it depends on nothing but the length.
/// `crc32_combine_op` then applies the precomputed value cheaply
/// (`src/crc32.c:969-974`).
///
/// So this is the shape for combining the same second run many times: compute the
/// operator once, then call `crc32_combine_op` per pair. `crc32_combine` above is
/// the convenience route that does both halves every time.
///
/// A `len2` of zero does **not** make the operator zero, and it is worth being
/// exact about why: `src/crc32.c:184-195` is `x2nmodp`, its first line is
/// `p = (uLong)1 << 31; /* x^0 == 1 */`, and the loop that would change that is
/// `while (n)` - which a zero `n` never enters. The zero operator
/// `src/crc32.c:969-970` answers for is a separate one, and it answers zero
/// before any multiplication happens.
pub fn crc32_combine_gen(len2: usize) u32 {
    const value: c_ulong = c.crc32_combine_gen(@intCast(len2));
    return @truncate(value);
}

/// Combine two CRC-32 values with an operator from `crc32_combine_gen`.
///
/// `crc32_combine_op` (`src/zlib.h:1890`, `src/crc32.c:969-974`) is
/// `crc32_combine(crc1, crc2, len2)` with the expensive half already done. The
/// operator must be the one `crc32_combine_gen` returns **for this `len2`**; a
/// different one combines for a different length and the header says so at
/// `src/zlib.h:1887-1889`.
pub fn crc32_combine_op(crc1: u32, crc2: u32, op: u32) u32 {
    const value: c_ulong = c.crc32_combine_op(@intCast(crc1), @intCast(crc2), @intCast(op));
    return @truncate(value);
}

/// The two checksums' starting values.
///
/// zlib takes the previous value as a plain argument (`src/zlib.h:1809` and
/// `:1848`), and getting the two starts wrong is the classic way to get a
/// checksum that is subtly wrong rather than obviously wrong - both are `1`-or-`0`
/// and neither is checked. Naming them here means a caller does not have to
/// remember which is which.
pub const checksum = struct {
    /// The initial value for `adler32`: RFC 1950 §8.2's `s1 = 1`
    /// (`src/doc/rfc1950.txt:485-490`), which is the `1L` in
    /// `src/doc/rfc1950.txt:567-569`'s own sample code.
    pub const adler32_init: u32 = 1;

    /// The initial value for `crc32`: zero, which is the CRC-32 of no bytes.
    pub const crc32_init: u32 = 0;

    /// The Adler-32 of an empty slice. It is `adler32_init`, and asserting that
    /// through the library is what a test should do rather than restating it.
    pub fn adler32Empty() u32 {
        return adler32(adler32_init, "");
    }

    /// The CRC-32 of an empty slice: zero.
    pub fn crc32Empty() u32 {
        return crc32(crc32_init, "");
    }
};

/// An owning compressor.
///
/// One `z_stream`, allocated by upstream's allocator when `init` succeeds and
/// released when `deinit` runs. `deinit` takes `*Deflater`, calls `deflateEnd`
/// through the same `c` route that initialised it, and then zeroes the stream, so
/// calling it twice on the same variable is a no-op rather than a second
/// `deflateEnd`. Zig cannot make a struct non-copyable, so the remaining rule is
/// the usual one: copy a `Deflater` before `deinit` and you have two owners of
/// one stream, and only one of them should end it.
///
/// The memory behind it is libc's; see the module comment.
pub const Deflater = struct {
    /// The C stream. Zero until `init` succeeds.
    stream: c.z_stream,
    /// Which container `init` was asked for, kept so `format` can answer without
    /// re-deriving it from the caller's options.
    format: Format = .zlib,

    /// A stream that owns nothing.
    ///
    /// Zeroed rather than `undefined`, because `deflateEnd` on a stream that was
    /// never initialised must be detectable rather than a read of memory this
    /// package never wrote. `deinit` and `copyTo` both test `state` for null.
    pub const empty: Deflater = .{ .stream = std.mem.zeroes(c.z_stream) };

    /// Start a compressor writing `format`.
    ///
    /// This calls `deflateInit2_`, which is what the `deflateInit2` **macro**
    /// expands to (`src/zlib.h:1930-1932`): the macro supplies `ZLIB_VERSION` and
    /// `(int)sizeof(z_stream)`, and this supplies the same two values, so the
    /// version and struct size upstream checks (`src/deflate.c:326-338`) are the
    /// ones the headers declare rather than a restatement of them.
    ///
    /// `format.raw` is the only value that gives a bare deflate stream; the other
    /// two add a container that `Inflater` can read back, and `Format.windowBits`
    /// is where that mapping lives.
    ///
    /// `self` is initialised **in place**, and the caller has to say so, because
    /// upstream records the address of the stream it was handed and refuses
    /// every later call once that address no longer matches: `deflateStateCheck`
    /// in `src/deflate.c` tests `s->strm != strm`, and `inflateStateCheck` at
    /// `src/inflate.c:94` tests the same for the decompressor. A `z_stream`
    /// copied out of a function that returned it by value sits at a different
    /// address than the one upstream stored, so every later `deflate` and
    /// `inflate` on it returns `Z_STREAM_ERROR` and `deinit` reports that the
    /// stream it initialised was already broken. Upstream's every C caller keeps
    /// its `z_stream` where it declared it, which is what this shape is.
    ///
    /// On failure nothing is owned: the error comes back and `self` is zeroed
    /// again, so a `deinit` in a `defer` is safe whichever way `init` went.
    pub fn init(self: *Deflater, options: CompressOptions, format: Format) Error!void {
        self.* = .empty;
        errdefer self.* = .empty;
        const code = c.deflateInit2_(
            &self.stream,
            @intFromEnum(options.level),
            // `Z_DEFLATED` is a `#define` of `8`, so the translation makes it a
            // plain `c_int` constant, not an enum tag; `@intFromEnum` wants the
            // latter.
            @intCast(c.Z_DEFLATED),
            format.windowBits(),
            @intCast(options.mem_level),
            @intFromEnum(options.strategy),
            version,
            @sizeOf(c.z_stream),
        );
        try codeOrError(code);
        self.format = format;
    }

    /// Release the stream.
    ///
    /// `deflateEnd` (`src/zlib.h:367`) returns `Z_OK`, or `Z_STREAM_ERROR` for an
    /// inconsistent state, or `Z_DATA_ERROR` "if the stream was freed without
    /// being ended first" (`src/zlib.h:373-376`). That last case is exactly what a
    /// double `deinit` would be, which is why the struct is zeroed first: the
    /// second call sees `state == null` and returns.
    ///
    /// The code is checked, and a failure stops the program. A `deinit` that could
    /// fail would force every caller to handle an error in cleanup for a condition
    /// that can only mean a bug at this boundary.
    pub fn deinit(self: *Deflater) void {
        if (self.stream.state == null) return;
        const code = c.deflateEnd(&self.stream);
        self.stream = std.mem.zeroes(c.z_stream);
        if (code != @intFromEnum(Status.ok)) {
            std.debug.panic(
                "zlib: deflateEnd returned {d} ({s}) for a stream this module " ++
                    "initialised and had not ended; that is a bug in the caller, " ++
                    "not a condition to recover from\n",
                .{ code, zError(code) },
            );
        }
    }

    /// Which container this stream writes.
    pub fn container(self: *const Deflater) Format {
        return self.format;
    }

    /// The `z_stream`, for a caller that needs a declaration this module does not
    /// name.
    pub fn handle(self: *Deflater) *c.z_stream {
        return &self.stream;
    }

    /// Move input through the stream once.
    ///
    /// `deflate` (`src/zlib.h:254`) reads `avail_in`/`next_in` and
    /// `avail_out`/`next_out` from the stream and updates all four, so this writes
    /// them from the two slices before the call and reads the counts back after
    /// it. `Progress` is that arithmetic.
    ///
    /// The two non-failures come back as `status` rather than as an error:
    /// `Z_OK` means "there may be more" and `Z_STREAM_END` is the normal end
    /// (`src/zlib.h:331-335`). Everything else is an `Error`, which is why this
    /// can return one as well.
    pub fn run(self: *Deflater, input: []const u8, output: []u8, flush: Flush) Error!Progress {
        // `src/zconf.h` leaves `z_const` empty by default, so the translation
        // types `next_in` as `[*c]u8` even though `src/deflate.h:74-77` promises
        // zlib does not write through it. `@constCast` states that promise rather
        // than working around it.
        self.stream.next_in = if (input.len == 0) null else @constCast(input.ptr);
        self.stream.avail_in = @intCast(input.len);
        // `src/deflate.c` rejects a null `next_out` whatever `avail_out` says,
        // so an empty slice passes its own pointer rather than null: "no room
        // this time" is the state `src/zlib.h:332-336` tells a caller to call
        // again from, not a state to refuse the call in.
        self.stream.next_out = output.ptr;
        self.stream.avail_out = @intCast(output.len);

        const code = c.deflate(&self.stream, @intFromEnum(flush));
        const consumed = input.len - @as(usize, @intCast(self.stream.avail_in));
        const produced = output.len - @as(usize, @intCast(self.stream.avail_out));

        const status = try statusOf(code);
        if (status.errorCode()) |err| return err;
        return .{ .consumed = consumed, .produced = produced, .status = status };
    }

    /// Compress `input` into `output` until the stream ends.
    ///
    /// This is the loop `src/zlib.h:283-291` tells a caller to write: call
    /// `deflate` with `Z_NO_FLUSH` while there is input, then with `Z_FINISH`
    /// until it returns `Z_STREAM_END`. It stops on `Z_STREAM_END`, on an
    /// `Error`, or when neither slice can give it more room - and `Progress.status`
    /// says which, so a caller can tell "finished" from "output full".
    ///
    /// It cannot loop forever: with `Z_FINISH` and a non-empty output slice
    /// `deflate` makes progress every call, and a full slice is a return, not a
    /// spin.
    pub fn runAll(self: *Deflater, input: []const u8, output: []u8) Error!Progress {
        var total: Progress = .{ .consumed = 0, .produced = 0, .status = .ok };
        var rest = input;
        while (true) {
            const last = rest.len == 0;
            const step = try self.run(rest, output[total.produced..], if (last) .finish else .no_flush);
            total.consumed += step.consumed;
            total.produced += step.produced;
            total.status = step.status;
            if (step.status == .stream_end) return total;
            if (step.consumed == 0 and step.produced == 0) return total;
            rest = rest[step.consumed..];
        }
    }

    /// An upper bound on what `deflate` will produce for `source_len` bytes.
    ///
    /// `deflateBound` (`src/zlib.h:768`, documented at `:753-767`) is *this
    /// stream's* bound and it differs from `compressBound`: it accounts for the
    /// level and the window size this stream was initialised with, and it is what
    /// to size a buffer from when compressing through *this* stream.
    ///
    /// Upstream's only stated error is `Z_STREAM_ERROR` for an inconsistent
    /// stream, which is not reachable between `init` and `deinit`, so a zero
    /// answer here can only be that - and it is reported as `error.StreamError`
    /// rather than as a silent zero.
    pub fn bound(self: *Deflater, source_len: usize) Error!usize {
        const value: c_ulong = c.deflateBound(&self.stream, @intCast(source_len));
        if (value == 0) return error.StreamError;
        return @intCast(value);
    }

    /// Return the stream to its initial state, keeping its configuration.
    ///
    /// `deflateReset` (`src/zlib.h:702`, documented at `:695-700`) is
    /// "equivalent to deflateEnd followed by deflateInit, but does not free and
    /// reallocate the internal compression state": the level and every other
    /// attribute stay as they were, while `total_in`, `total_out`, `adler` and
    /// `msg` are reset.
    pub fn reset(self: *Deflater) Error!void {
        try codeOrError(c.deflateReset(&self.stream));
    }

    /// Change the level and strategy mid-stream.
    ///
    /// `deflateParams` (`src/zlib.h:713`, documented at `:717-748`) takes effect
    /// at the next `deflate` call. If there has been compression since the last
    /// reset, the input so far is finished with the *old* settings first - which
    /// is why `:739-748` warns the change may need more than one call and more
    /// output room than the caller expected.
    pub fn params(self: *Deflater, level: Level, strategy: Strategy) Error!void {
        try codeOrError(c.deflateParams(
            &self.stream,
            @intFromEnum(level),
            @intFromEnum(strategy),
        ));
    }

    /// What `deflate` has produced but not yet flushed, and how much of the
    /// compressor's own state is in use.
    ///
    /// All three values come back in `Pending`, from `deflatePending`'s two output
    /// pointers and `deflateUsed`'s one.
    pub fn pending(self: *Deflater) Error!Pending {
        var bytes: c_uint = 0;
        var bits: c_uint = 0;
        try codeOrError(c.deflatePending(&self.stream, &bytes, &bits));
        const used: c_ulong = c.deflateUsed(&self.stream);
        return .{
            .bytes = @intCast(bytes),
            // `src/zlib.h:783-785` documents 0 for an empty pending buffer, so a
            // value above 7 is upstream not meaning what the name says.
            .bits = @intCast(@min(bits, 7)),
            .used = @intCast(used),
        };
    }

    /// Input bytes consumed since the last reset (`src/zlib.h:93`).
    pub fn totalIn(self: *const Deflater) usize {
        return @intCast(self.stream.total_in);
    }

    /// Output bytes produced since the last reset (`src/zlib.h:95`).
    pub fn totalOut(self: *const Deflater) usize {
        return @intCast(self.stream.total_out);
    }

    /// Duplicate this stream's state into `dest`.
    ///
    /// `deflateCopy` (`src/zlib.h:684`) writes into a destination that has **not**
    /// been initialised: upstream's own wording at `:696-699` is that it
    /// "duplicates the internal compression state", so `dest` is filled rather
    /// than reset. A destination that already owned a stream would leak it, so
    /// `dest` must be `Deflater.empty` and its owner must `deinit` it exactly as
    /// it would an initialised one.
    ///
    /// Upstream also notes at `:690-693` that this strategy "is slow and can
    /// consume lots of memory". It is exposed because it is the only way to have
    /// two compressors over the same state, not because it is cheap.
    pub fn copyTo(self: *const Deflater, dest: *Deflater) Error!void {
        if (dest.stream.state != null) {
            std.debug.panic(
                "zlib: deflateCopy was given a destination that already owns a " ++
                    "stream; upstream fills the destination rather than resetting " ++
                    "it, so the existing state would be leaked. Pass Deflater.empty.",
                .{},
            );
        }
        try codeOrError(c.deflateCopy(&dest.stream, &self.stream));
    }
};

/// An owning decompressor.
///
/// The mirror of `Deflater`, with the same ownership rule: `deinit` calls
/// `inflateEnd` once and then zeroes the struct, and the memory behind it is
/// libc's.
///
/// One thing differs and it matters for correctness: `inflateInit2`'s
/// `windowBits` **selects the format** rather than only the history size.
/// `Format.gzip` is 31, and `src/zlib.h:513-516` is explicit that a zlib header
/// where a gzip one was expected is `Z_DATA_ERROR` rather than an auto-detect.
/// `Inflater.init` therefore takes a `Format`, and `Format.windowBits` is the
/// single place the mapping is written down.
pub const Inflater = struct {
    /// The C stream. Zero until `init` succeeds.
    stream: c.z_stream,
    /// Which container `init` was asked for. Kept because `readHeader` has to
    /// know whether there is a gzip header at all, and re-deriving it from the
    /// options would be a second place to get it wrong.
    format: Format = .zlib,

    /// A stream that owns nothing; see `Deflater.empty`.
    pub const empty: Inflater = .{ .stream = std.mem.zeroes(c.z_stream) };

    /// Start a decompressor reading `format`.
    ///
    /// This calls `inflateInit2_`, which is what the `inflateInit2` **macro**
    /// expands to (`src/zlib.h:1935-1937`), and passes the same `ZLIB_VERSION`
    /// and `sizeof(z_stream)` the macro would.
    ///
    /// `format.raw` is a bare deflate stream with no header and no trailer;
    /// `format.zlib` is the RFC 1950 wrapper; `format.gzip` is the RFC 1952
    /// wrapper. `Format.windowBits` is what makes `inflate` read one rather than
    /// another, and it is why a gzip stream read as `.zlib` fails rather than
    /// working by accident.
    ///
    /// `self` is initialised **in place**, for the reason `Deflater.init` gives:
    /// `inflateStateCheck` at `src/inflate.c:88-98` rejects a stream whose
    /// recorded `state->strm` is no longer the stream it was given, and a value
    /// returned out of a function is copied to a new address.
    ///
    /// On failure nothing is owned: `self` is zeroed again before the error
    /// leaves, so a `deinit` in a `defer` is safe whichever way `init` went.
    pub fn init(self: *Inflater, format: Format) Error!void {
        self.* = .empty;
        errdefer self.* = .empty;
        const code = c.inflateInit2_(
            &self.stream,
            format.windowBits(),
            version,
            @sizeOf(c.z_stream),
        );
        try codeOrError(code);
        self.format = format;
    }

    /// Release the stream.
    ///
    /// `inflateEnd` (`src/zlib.h:525`); see `Deflater.deinit` for the same
    /// contract and the same reasoning.
    pub fn deinit(self: *Inflater) void {
        if (self.stream.state == null) return;
        const code = c.inflateEnd(&self.stream);
        self.stream = std.mem.zeroes(c.z_stream);
        if (code != @intFromEnum(Status.ok)) {
            std.debug.panic(
                "zlib: inflateEnd returned {d} ({s}) for a stream this module " ++
                    "initialised and had not ended; that is a bug in the caller, " ++
                    "not a condition to recover from\n",
                .{ code, zError(code) },
            );
        }
    }

    /// Which container this stream reads.
    pub fn container(self: *const Inflater) Format {
        return self.format;
    }

    /// The `z_stream`, for a caller that needs a declaration this module does not
    /// name.
    pub fn handle(self: *Inflater) *c.z_stream {
        return &self.stream;
    }

    /// Move input through the stream once.
    ///
    /// `inflate` (`src/zlib.h:405`) uses the same four fields as `deflate`, so
    /// this is the same arithmetic. `Z_STREAM_END` is returned rather than raised:
    /// `src/zlib.h:467-470` says to call `inflate` until it returns `Z_STREAM_END`,
    /// and that is the answer the loop is waiting for.
    pub fn run(self: *Inflater, input: []const u8, output: []u8, flush: Flush) Error!Progress {
        // As in `Deflater.run`: `z_const` is empty by default, so `next_in` is
        // `[*c]u8` in the translation and zlib does not write through it.
        self.stream.next_in = if (input.len == 0) null else @constCast(input.ptr);
        self.stream.avail_in = @intCast(input.len);
        // `src/inflate.c:494` refuses a null `next_out` on the same terms as
        // `deflate`, and the empty slice is a valid pointer to a zero-length
        // place to write nothing.
        self.stream.next_out = output.ptr;
        self.stream.avail_out = @intCast(output.len);

        const code = c.inflate(&self.stream, @intFromEnum(flush));
        const consumed = input.len - @as(usize, @intCast(self.stream.avail_in));
        const produced = output.len - @as(usize, @intCast(self.stream.avail_out));

        const status = try statusOf(code);
        if (status.errorCode()) |err| return err;
        return .{ .consumed = consumed, .produced = produced, .status = status };
    }

    /// Decompress `input` into `output` until the stream ends.
    ///
    /// The loop `src/zlib.h:467-472` describes: keep calling `inflate` until
    /// `Z_STREAM_END`. It stops on `Z_STREAM_END`, on an `Error`, or when neither
    /// slice can give it more room, and `Progress.status` says which.
    ///
    /// **A truncated stream ends here as `error.BufError`, not as a short
    /// output.** `src/zlib.h:515-518` calls `Z_BUF_ERROR` "not fatal" but it is
    /// what an `inflate` with no more input and no more output room returns, and
    /// nothing in `src/inflate.c` invents an end-of-stream for a stream that did
    /// not send one. The output produced before that is in `Progress.produced` and
    /// the bytes past it in `output` are untouched.
    pub fn runAll(self: *Inflater, input: []const u8, output: []u8) Error!Progress {
        var total: Progress = .{ .consumed = 0, .produced = 0, .status = .ok };
        var rest = input;
        while (true) {
            const step = try self.run(rest, output[total.produced..], .no_flush);
            total.consumed += step.consumed;
            total.produced += step.produced;
            total.status = step.status;
            if (step.status == .stream_end) return total;
            if (step.consumed == 0 and step.produced == 0) return total;
            rest = rest[step.consumed..];
        }
    }

    /// Input bytes consumed since the last reset (`src/zlib.h:93`).
    ///
    /// Present on a decompressor for the same reason it is present on a
    /// compressor: `total_in` is a field of the shared `z_stream`
    /// (`src/zlib.h:90-110`) rather than of a direction, and `inflateReset`
    /// zeroes it along with `total_out`, `adler` and `msg` (`src/zlib.h:698-700`).
    pub fn totalIn(self: *const Inflater) usize {
        return @intCast(self.stream.total_in);
    }

    /// Output bytes produced since the last reset (`src/zlib.h:95`).
    pub fn totalOut(self: *const Inflater) usize {
        return @intCast(self.stream.total_out);
    }

    /// Return the stream to its initial state, keeping its configuration.
    ///
    /// `inflateReset` (`src/zlib.h:986`, documented at `:979-984`). This is what
    /// makes a stream that returned `Z_DATA_ERROR` usable again: the error is a
    /// property of the input that was fed, not of the stream. `tests.zig` checks
    /// exactly that - one corrupt stream, one `reset`, one good stream after it.
    pub fn reset(self: *Inflater) Error!void {
        try codeOrError(c.inflateReset(&self.stream));
    }

    /// Skip forward to the next full-flush point.
    ///
    /// `inflateSync` (`src/zlib.h:951`, documented at `:944-949`) discards input
    /// up to and including the next `Z_FULL_FLUSH` point, so a stream interrupted
    /// mid-block can be resumed from the next block boundary. It is the operation
    /// that makes `Z_FULL_FLUSH`-written data seekable, and it reports
    /// `Z_DATA_ERROR` when no such point exists in the input given.
    pub fn sync(self: *Inflater) Error!void {
        try codeOrError(c.inflateSync(&self.stream));
    }

    /// Where the decoder is, for random access over a stream.
    ///
    /// `inflateMark` (`src/zlib.h:1042`, documented at `:1046-1068`) returns a
    /// `long` packing two numbers: the upper half is the number of bits back from
    /// the current bit position and the lower 16 bits are the number of bytes
    /// already emitted for the code being processed. An upper value of `-1` means
    /// the decoder is outside a block (`-1` with a zero lower value) or in the
    /// middle of a stored block (`-1` with the lower value counting the bytes left
    /// to copy). `-65536` is the answer for an inconsistent stream.
    ///
    /// The two numbers are returned separately rather than as the packed `long`,
    /// because unpacking it is the reader's arithmetic otherwise.
    pub fn mark(self: *const Inflater) Mark {
        // `packed` is a Zig keyword, so this binding cannot carry the name the
        // C return value has.
        const raw_long: c_long = c.inflateMark(&self.stream);
        if (raw_long == -65536) return .{ .bits_back = null, .bytes_out = null, .failed = true };
        // `c_long` is the target's C `long`: 64 bits under LP64 and 32 on
        // `x86_64-windows-gnu`. Upstream packs `bits_back` into bits 31..16
        // (`src/inflate.c:inflateMark` shifts `state->back` left by sixteen), so
        // the low 32 bits carry both numbers and a `@truncate` reads them on
        // either width.
        const raw: u32 = @truncate(raw_long);
        const upper: i16 = @bitCast(@as(u16, @truncate(raw >> 16)));
        const lower: u16 = @truncate(raw);
        return .{
            .bits_back = upper,
            .bytes_out = lower,
            .failed = false,
        };
    }

    /// Ask for the gzip member header of the next member read, and return it.
    ///
    /// `inflateGetHeader` (`src/zlib.h:1070`) writes the header's fields into a
    /// caller-supplied `gz_header` (`src/zlib.h:118-133`) as it reads it, and
    /// `src/zlib.h:1073-1075` requires it to be called after `init` or `reset`
    /// and before the first `inflate`.
    ///
    /// This module does not take a raw `gz_header` from the caller, for a reason
    /// that is about safety rather than taste: the three buffer fields (`name`,
    /// `comment`, `extra`) are pointers **upstream writes through**, bounded only
    /// by the `*_max` value beside each one. A caller-supplied pointer-and-length
    /// pair is the shape in which a mistake is a buffer overflow. `HeaderBuffer`
    /// supplies the storage, and this method is the only way to ask, so the buffer
    /// and the capacities are always one value.
    ///
    /// A stream in `.zlib` or `.raw` format has no gzip header to read, so this is
    /// `error.StreamError` for those rather than a header full of zeroes that look
    /// like a real one.
    ///
    /// Upstream keeps the **pointer** it is handed and fills that struct during
    /// a later `inflate`, so the `gz_header` lives in `buffers` rather than in a
    /// value built here: a `gz_header` in a temporary would be filled into memory
    /// that no longer exists once this returned, and the three string pointers -
    /// the only parts of it that happened to point at caller-owned storage -
    /// would be the only ones to survive. Read the fields afterwards with
    /// `HeaderBuffer.current`.
    ///
    /// A stream in `.zlib` or `.raw` format has no gzip header to read, so this is
    /// `error.StreamError` for those rather than a header full of zeroes that look
    /// like a real one.
    pub fn readHeader(self: *Inflater, buffers: *HeaderBuffer) Error!void {
        if (self.format != .gzip) return error.StreamError;
        // `src/inflate.c` writes through the three pointers the header carries
        // (`src/zlib.h:118-133`), which is why this module keeps the storage and
        // the capacities as one value rather than taking them separately.
        buffers.head = std.mem.zeroes(c.gz_header);
        buffers.head.extra = buffers.extra[0..].ptr;
        buffers.head.extra_max = @intCast(buffers.extra.len);
        buffers.head.name = buffers.name[0..].ptr;
        buffers.head.name_max = @intCast(buffers.name.len);
        buffers.head.comment = buffers.comment[0..].ptr;
        buffers.head.comm_max = @intCast(buffers.comment.len);
        try codeOrError(c.inflateGetHeader(&self.stream, &buffers.head));
    }

    /// Duplicate this stream's state into `dest`.
    ///
    /// `inflateCopy` (`src/zlib.h:970`) has the same destination contract as
    /// `deflateCopy`: `dest` is filled, not reset, so it must be
    /// `Inflater.empty`. Upstream's note at `:976-979` that the source state can
    /// be large is why nothing in this package's own tests uses it on a hot path.
    pub fn copyFrom(self: *const Inflater, dest: *Inflater) Error!void {
        if (dest.stream.state != null) {
            std.debug.panic(
                "zlib: inflateCopy was given a destination that already owns a " ++
                    "stream; upstream fills the destination rather than resetting " ++
                    "it, so the existing state would be leaked. Pass Inflater.empty.",
                .{},
            );
        }
        try codeOrError(c.inflateCopy(&dest.stream, &self.stream));
    }
};

/// Where a stream's decoder is, as `inflateMark` reports it.
///
/// All three states the header describes (`src/zlib.h:1048-1066`) are
/// representable: `bits_back` is null-able and is `-1` both outside a block (with
/// `bytes_out == 0`) and inside a stored one (with `bytes_out > 0`), and `failed`
/// is the `-65536` answer for an inconsistent stream.
pub const Mark = struct {
    /// Bits back from the current bit position, or null when the decoder is
    /// outside a block or inside a stored one.
    bits_back: ?i32,
    /// Bytes already emitted for the code being processed, or null when the
    /// stream was inconsistent.
    bytes_out: ?u16,
    /// Whether `inflateMark` returned `-65536`.
    failed: bool,
};

/// The gzip member header, as `src/zlib.h:118-133` declares it.
///
/// Every pointer and length here is written by **upstream**, not by the caller:
/// `src/inflate.c` copies the file name, the comment and the extra field into the
/// buffers the header points at, up to the `*_max` bounds. That is why this
/// struct is only ever produced by `Inflater.readHeader` from a `HeaderBuffer` the
/// caller owns, and why nothing in it is a slice into a longer-lived allocation:
/// the bytes are the caller's, and they last exactly as long as the
/// `HeaderBuffer`.
///
/// Every optional field defaults to null and every flag to `false`, so `.{ .{} }`
/// is a valid literal and means "nothing was supplied". `src/zlib.h:118-133`
/// declares the three pointers as plain `Bytef *`, which is what makes the
/// defaults load-bearing rather than decorative: a null there is upstream's own
/// "this field is absent", not a sentinel this module invented.
pub const GzipHeader = struct {
    /// `src/zlib.h:119`: "true if compressed data believed to be text". RFC 1952
    /// defines this bit as FTEXT (`src/doc/rfc1952.txt:300-306`).
    text: bool = false,
    /// `src/zlib.h:120`: MTIME in RFC 1952 (`src/doc/rfc1952.txt:364-372`), where
    /// zero means no timestamp is available.
    time: u32 = 0,
    /// `src/zlib.h:121`: XFL, "extra flags (not used when writing a gzip file)".
    /// RFC 1952 gives 2 for maximum compression and 4 for fastest
    /// (`src/doc/rfc1952.txt:374-381`).
    xflags: i32 = 0,
    /// `src/zlib.h:122`: the operating system that produced the file
    /// (`src/doc/rfc1952.txt:383`).
    os: i32 = 0,
    /// `src/zlib.h:123`: the extra field, or null when FEXTRA was not set. A
    /// borrow into the caller's `HeaderBuffer.extra`.
    extra: ?[*]u8 = null,
    /// `src/zlib.h:124`: how many bytes of `extra` are valid.
    extra_len: u32 = 0,
    /// `src/zlib.h:125`: how many bytes of space upstream may write into `extra`.
    /// Read only while a header is being read; null here means "no buffer".
    extra_max: u32 = 0,
    /// `src/zlib.h:126`: the zero-terminated original file name, or null when
    /// FNAME was not set. A borrow into the caller's `HeaderBuffer.name`.
    name: ?[*]u8 = null,
    /// `src/zlib.h:127`: how many bytes of space upstream may write into `name`.
    name_max: u32 = 0,
    /// `src/zlib.h:128`: the zero-terminated file comment, or null when FCOMMENT
    /// was not set. A borrow into the caller's `HeaderBuffer.comment`.
    comment: ?[*]u8 = null,
    /// `src/zlib.h:129`: how many bytes of space upstream may write into
    /// `comment`.
    comm_max: u32 = 0,
    /// `src/zlib.h:130`: whether the header carried an FHCRC. RFC 1952 records
    /// that this bit "was never set by versions of gzip up to 3.7"
    /// (`src/doc/rfc1952.txt:329`).
    hcrc: bool = false,
    /// `src/zlib.h:131`: true once upstream has finished reading the header.
    done: bool = false,

    /// The file name, or null when FNAME was not set or the buffer ran out.
    ///
    /// A **borrow** into the caller's `HeaderBuffer`, not a copy and not library
    /// memory. RFC 1952 defines the field as a NUL-terminated string
    /// (`src/doc/rfc1952.txt:343-346`) and upstream stops at `name_max`, so this
    /// stops at whichever comes first.
    pub fn nameSlice(self: GzipHeader) ?[:0]const u8 {
        const raw = self.name orelse return null;
        if (self.name_max == 0) return null;
        const window = raw[0..@intCast(self.name_max)];
        const end = std.mem.indexOfScalar(u8, window, 0) orelse return null;
        return window[0..end :0];
    }

    /// The comment, or null; a borrow exactly like `nameSlice`.
    pub fn commentSlice(self: GzipHeader) ?[:0]const u8 {
        const raw = self.comment orelse return null;
        if (self.comm_max == 0) return null;
        const window = raw[0..@intCast(self.comm_max)];
        const end = std.mem.indexOfScalar(u8, window, 0) orelse return null;
        return window[0..end :0];
    }

    /// The extra field, or null; a borrow exactly like `nameSlice`.
    ///
    /// There is no NUL search here, and that is not an inconsistency: RFC 1952
    /// gives FEXTRA a *length* and not a terminator
    /// (`src/doc/rfc1952.txt:325-328`).
    pub fn extraSlice(self: GzipHeader) ?[]const u8 {
        const raw = self.extra orelse return null;
        if (self.extra_len > self.extra_max) return null;
        return raw[0..@intCast(self.extra_len)];
    }
};

/// Storage a `gz_header` and the three optional fields it points at.
///
/// `src/zlib.h:118-133` describes `extra`, `name` and `comment` as pointers the
/// caller supplies with a matching `*_max` capacity, and `src/inflate.c` writes
/// into them. A struct like this is the shape in which that is safe: the storage
/// and the capacities are one value, they cannot be separated, and the buffer is
/// declared in the same frame as the header that points into it.
///
/// `head` is the header itself rather than a copy of it, for the reason
/// `Inflater.readHeader` gives: `inflateGetHeader` stores the pointer and fills
/// it later, so the struct upstream writes into has to outlive the call that
/// registered it. That is this field's whole job.
///
/// 256 bytes for the name and the comment, 64 for the extra field. Neither limit
/// is upstream's: RFC 1952 gives no maximum for FNAME or FCOMMENT and
/// `src/inflate.c` simply truncates at `*_max` and sets the header's `done` flag
/// regardless. These are this module's chosen sizes, and a caller needing longer
/// can build its own `c.gz_header` and use `c.inflateGetHeader` directly.
pub const HeaderBuffer = struct {
    /// Where `src/inflate.c` writes the header fields. Zero until
    /// `Inflater.readHeader` has registered it.
    head: c.gz_header = std.mem.zeroes(c.gz_header),
    /// Destination for FNAME.
    name: [256]u8 = undefined,
    /// Destination for FCOMMENT.
    comment: [256]u8 = undefined,
    /// Destination for FEXTRA.
    extra: [64]u8 = undefined,

    /// The header as it stands now.
    ///
    /// Zeroes until a member has been parsed, and `done` is what says so:
    /// `src/zlib.h:1076-1078` is explicit that `head->done` is "zero until the
    /// header is completed", and every other field is filled at the same moment.
    /// Reading this before the first `run`/`runAll` therefore reports an absent
    /// header rather than a parsed one.
    pub fn current(self: *const HeaderBuffer) GzipHeader {
        return .{
            .text = self.head.text != 0,
            .time = @intCast(self.head.time),
            .xflags = self.head.xflags,
            .os = self.head.os,
            .extra = self.head.extra,
            .extra_len = @intCast(self.head.extra_len),
            .extra_max = @intCast(self.head.extra_max),
            .name = self.head.name,
            .name_max = @intCast(self.head.name_max),
            .comment = self.head.comment,
            .comm_max = @intCast(self.head.comm_max),
            .hcrc = self.head.hcrc != 0,
            .done = self.head.done != 0,
        };
    }
};

/// An owning `gzFile`: upstream's gzip *file* layer, distinct from a raw deflate
/// stream.
///
/// This is the `gz*` half of the API - the six units of `OBJG` at
/// `src/Makefile.in:60`, which are `compress.c`, `uncompr.c`, `gzclose.c`,
/// `gzlib.c`, `gzread.c` and `gzwrite.c` - and it is a file abstraction: it
/// opens a path, it has a position, and it can report that it is reading a file
/// through transparently rather than decompressing.
///
/// `gzFile` is `struct gzFile_s *` (`src/zlib.h:1354`) and is semi-opaque by
/// upstream's own word, so nothing here reaches through it. `deinit` closes it
/// once and then clears the handle, so a second `deinit` is a no-op rather than a
/// double close; a copy made before `deinit` is two owners of one file, of which
/// only one should close it.
///
/// The memory behind it - the internal state, and any read or write buffer - is
/// libc's, through the same `malloc`/`free` path as a stream.
pub const Gzip = struct {
    /// The C handle. Null until an `init` succeeds.
    handle_: ?*c.gzFile_s,

    /// A handle that owns nothing; see `Deflater.empty`.
    pub const empty: Gzip = .{ .handle_ = null };

    /// Open `path` for reading.
    ///
    /// `gzopen` (`src/zlib.h:1357`) is this layer's `fopen`, and its mode string
    /// has one extension: a trailing `g` means *create* for writing, and is not an
    /// `fopen` mode (`src/zlib.h:1367-1372`).
    ///
    /// A null return covers two very different reasons - the file could not be
    /// opened, or the `gzFile` state could not be allocated
    /// (`src/zlib.h:1380-1390`) - and zlib does not tell them apart. That is
    /// `error.OpenFailed` and nothing finer, because inventing the distinction
    /// would mean reading `errno` upstream did not ask anyone to read.
    ///
    /// Opening a file that is **not** in gzip format is not an error:
    /// `src/zlib.h:1461-1463` says `gzread` copies the bytes through directly, and
    /// `gzdirect` reports it afterwards.
    pub fn openRead(path: [:0]const u8) Error!Gzip {
        return Gzip.init(path, "rb");
    }

    /// Open `path` for writing, creating it and truncating an existing file.
    ///
    /// The mode is `"wb"`, and the gzip container is added for you: `src/gzwrite.c`
    /// writes the RFC 1952 header and the CRC-32 plus ISIZE trailer around the
    /// deflate stream.
    pub fn openWrite(path: [:0]const u8) Error!Gzip {
        return Gzip.init(path, "wb");
    }

    /// Open `path` with an explicit `gzopen` mode string.
    ///
    /// `mode` is passed through verbatim, so anything `src/zlib.h:1360-1372`
    /// accepts works and this method does not have to enumerate it.
    pub fn init(path: [:0]const u8, mode: [:0]const u8) Error!Gzip {
        // `handle` is this type's own method name, so the local cannot be.
        const gz = c.gzopen(path.ptr, mode.ptr);
        return .{ .handle_ = gz orelse return error.OpenFailed };
    }

    /// Wrap a file descriptor this process already owns.
    ///
    /// `gzdopen` (`src/zlib.h:1404`) takes an `fd` the caller owns and does **not**
    /// close: `src/zlib.h:1410-1413` is explicit that "the caller is responsible
    /// for closing the file descriptor". So this method's `deinit` ends the gzip
    /// layer and leaves the descriptor alone - a different ownership rule from
    /// `openRead`/`openWrite`, where `gzclose` closes the descriptor too.
    pub fn adopt(fd: c_int, mode: [:0]const u8) Error!Gzip {
        const gz = c.gzdopen(fd, mode.ptr);
        return .{ .handle_ = gz orelse return error.OpenFailed };
    }

    /// Close the file.
    ///
    /// `gzclose` (`src/zlib.h:1750`, documented at `:1741-1749`) flushes and
    /// frees the internal state and closes the descriptor for a file `gzopen`
    /// opened. It returns `Z_OK`, `Z_BUF_ERROR` (not enough room in the output
    /// buffer for the last flush), `Z_STREAM_ERROR` (the handle is not valid) or
    /// `Z_ERRNO` on a file error.
    ///
    /// **A failed close still released everything**: `src/gzclose.c` frees the
    /// state and closes the file before it decides the return code. So this closes
    /// unconditionally and then reports. That is why it cannot panic and why the
    /// caller that cares reads `lastError` *before* closing.
    pub fn deinit(self: *Gzip) void {
        const gz = self.handle_ orelse return;
        self.handle_ = null;
        _ = c.gzclose(gz);
    }

    /// The C handle, for a caller that needs a declaration this module does not
    /// name.
    pub fn handle(self: *const Gzip) ?*c.gzFile_s {
        return self.handle_;
    }

    /// Read up to `dst.len` bytes, returning how many were read.
    ///
    /// `gzread` (`src/zlib.h:1456`) returns the number of uncompressed bytes
    /// actually read, "less than len for end of file, or -1 for error"
    /// (`src/zlib.h:1490-1493`). So a short read is a normal answer and only
    /// `-1` is a failure - and what that failure *is* comes from `gzerror`, which
    /// is where upstream tells the caller to look (`src/zlib.h:1484-1488`).
    ///
    /// So this reads the error code out of the handle rather than guessing, and
    /// reports `error.EndOfInput` for the zero that ends a stream.
    ///
    /// `src/zlib.h:1466-1471` is worth knowing before relying on a zero: a zero
    /// also means "the input ended in the middle of a gzip stream", and that
    /// condition is deferred to `gzclose`, which will return `Z_BUF_ERROR`. So a
    /// truncated member looks like end of input here and is caught at close.
    pub fn read(self: *Gzip, dst: []u8) Error!usize {
        const gz = self.require();
        const got: c_int = c.gzread(gz, if (dst.len == 0) undefined else dst.ptr, @intCast(dst.len));
        if (got < 0) return self.reportedError(error.EndOfInput);
        if (got == 0) return error.EndOfInput;
        return @intCast(got);
    }

    /// Read up to `dst.len` bytes, reporting end of input as a zero rather than
    /// an error.
    ///
    /// `read` above names the end of input, which is right for a loop that wants
    /// to stop. This is the shape for a caller that just wants "as many as there
    /// are", and it exists because that is a genuinely different question: a
    /// `fread`-shaped loop and an "all of it" loop read the same bytes and branch
    /// differently.
    pub fn readSome(self: *Gzip, dst: []u8) Error!usize {
        const gz = self.require();
        const got: c_int = c.gzread(gz, if (dst.len == 0) undefined else dst.ptr, @intCast(dst.len));
        if (got < 0) return self.reportedError(error.EndOfInput);
        return @intCast(got);
    }

    /// Write `bytes`, returning how many were written.
    ///
    /// `gzwrite` (`src/zlib.h:1519`, documented at `:1521-1528`) returns the
    /// number of uncompressed bytes written, "or 0 in case of error or if len is
    /// 0". A non-empty request that produced nothing is the error case, and it is
    /// `error.NotWritable` here - with the underlying code read out of the handle,
    /// because upstream's only documented cause for a zero is "error or len is 0"
    /// and this method has already ruled the second out.
    pub fn write(self: *Gzip, bytes: []const u8) Error!usize {
        const gz = self.require();
        const put: c_int = c.gzwrite(gz, if (bytes.len == 0) undefined else bytes.ptr, @intCast(bytes.len));
        if (put < 0) return self.reportedError(error.NotWritable);
        if (put == 0 and bytes.len != 0) return error.NotWritable;
        return @intCast(put);
    }

    /// Read one line into `dst`, NUL-terminated, or null at end of input.
    ///
    /// `gzgets` (`src/zlib.h:1588`, documented at `:1578-1587`) reads at most
    /// `dst.len - 1` bytes and always NUL-terminates. `dst.len` is the `len`
    /// the C takes, and a buffer of length 1 is upstream's own documented way to
    /// ask "is there a line?" without taking one.
    ///
    /// The returned slice is a borrow into `dst`, which the caller owns, and it
    /// is `[:0]const u8` because `gzgets` guarantees the terminator.
    pub fn gets(self: *Gzip, dst: []u8) Error!?[:0]const u8 {
        const gz = self.require();
        const raw = c.gzgets(gz, if (dst.len == 0) undefined else dst.ptr, @intCast(dst.len));
        const line = raw orelse return null;
        return std.mem.span(@as([*:0]u8, @ptrCast(line)));
    }

    /// Read one byte, or null at end of input.
    ///
    /// This is the `gzgetc_` function (`src/zlib.h:1961`) rather than the
    /// `gzgetc` **macro** (`src/zlib.h:1968-1971`), and the difference is worth
    /// stating: the macro reads three fields of `struct gzFile_s` through a
    /// pointer, and upstream's own comment at `:1959-1963` calls those fields
    /// "exposed elements" that "can only be used by the `gzgetc` macro". Reaching
    /// for the macro is reaching past the API; the function underneath is the one
    /// the macro falls back to when the pushback buffer is empty.
    pub fn getByte(self: *Gzip) Error!?u8 {
        const gz = self.require();
        const value: c_int = c.gzgetc_(gz);
        if (value < 0) return null;
        return @intCast(value);
    }

    /// Push one byte back, so the next read returns it again.
    ///
    /// `gzungetc` (`src/zlib.h:1630`) pushes back exactly one byte, and
    /// `src/zlib.h:1620-1629` is explicit that only the last read byte may be
    /// pushed. Pushing back a byte that was never read is `Z_DATA_ERROR`, which
    /// is `error.DataError` here.
    pub fn ungetByte(self: *Gzip, byte: u8) Error!void {
        const gz = self.require();
        try codeOrError(c.gzungetc(@intCast(byte), gz));
    }

    /// Write one byte.
    ///
    /// `gzputc` (`src/zlib.h:1607`, documented at `:1596-1606`) is a real
    /// function, not a macro, so this is `gzputc` called directly. It returns the
    /// byte written, or -1 on a file error, which is `error.Errno` here.
    pub fn putByte(self: *Gzip, byte: u8) Error!void {
        const gz = self.require();
        const put: c_int = c.gzputc(gz, @intCast(byte));
        if (put < 0) return error.Errno;
    }

    /// Write `text` followed by a newline.
    ///
    /// `gzputs` (`src/zlib.h:1575`, documented at `:1565-1574`) appends a
    /// NUL-terminated string and then a newline.
    ///
    /// The parameter is a **sentinel-terminated slice** rather than a plain one,
    /// and that is deliberate rather than awkward: upstream takes a C string, and
    /// converting an arbitrary `[]const u8` to one would mean either a copy into
    /// a fixed buffer (which would silently truncate) or a NUL byte somewhere
    /// upstream does not promise to have one. Taking the sentinel puts the
    /// requirement on the argument, where the compiler checks it.
    pub fn puts(self: *Gzip, text: [:0]const u8) Error!void {
        const gz = self.require();
        const put: c_int = c.gzputs(gz, text.ptr);
        if (put < 0) return error.Errno;
    }

    /// Move the read/write position, in uncompressed bytes.
    ///
    /// `gzseek` (`src/zlib.h:1663`, documented at `:1653-1662`). For reading it
    /// can only seek **forward** from the current position - `src/zlib.h:1670-1673`
    /// is explicit that seeking backwards in a gzip file means re-reading and
    /// discarding - and the position it reports is the uncompressed one.
    /// `offset` gives the compressed position instead.
    ///
    /// The origin is libc's `SEEK_SET`/`SEEK_CUR`/`SEEK_END`, which
    /// `src/zconf.h:511-514` defines itself when `unistd.h` did not. A `-1`
    /// return is a file error and is `error.Errno` here.
    pub fn seek(self: *Gzip, distance: i64, origin: SeekOrigin) Error!i64 {
        const gz = self.require();
        const at = c.gzseek(gz, @intCast(distance), @intFromEnum(origin));
        if (at == -1) return error.Errno;
        return @intCast(at);
    }

    /// The current position, in uncompressed bytes.
    ///
    /// `gztell` (`src/zlib.h:1691`, documented at `:1685-1690`); `-1` on a file
    /// error, which is `error.Errno` here.
    pub fn tell(self: *Gzip) Error!i64 {
        const gz = self.require();
        const at = c.gztell(gz);
        if (at == -1) return error.Errno;
        return @intCast(at);
    }

    /// The current position in the compressed file, in bytes.
    ///
    /// `gzoffset` (`src/zlib.h:1702`, documented at `:1696-1701`). This is the
    /// number `seek` needs to resume reading at, and it is the whole reason
    /// `gzoffset` exists: it is the only way to get from an uncompressed position
    /// to a compressed one.
    pub fn offset(self: *Gzip) Error!u64 {
        const gz = self.require();
        const at = c.gzoffset(gz);
        if (at == -1) return error.Errno;
        return @intCast(at);
    }

    /// Go back to the start of the file.
    ///
    /// `gzrewind` (`src/zlib.h:1683`, documented at `:1677-1682`) is a seek to
    /// zero with `SEEK_SET`, and it is the one backward move that is cheap: it
    /// discards the read buffer instead of re-reading.
    pub fn rewind(self: *Gzip) Error!void {
        const gz = self.require();
        try codeOrError(c.gzrewind(gz));
    }

    /// Whether the end of the compressed file has been reached.
    ///
    /// `gzeof` (`src/zlib.h:1711`, documented at `:1705-1710`) reports on the
    /// *underlying* file, so it can be true while there is still buffered output
    /// to read. It is a hint for a loop's condition, not a substitute for
    /// checking a read - which is why a closed `Gzip` answers true rather than
    /// crashing on a null handle.
    pub fn eof(self: *Gzip) bool {
        const gz = self.handle_ orelse return true;
        return c.gzeof(gz) != 0;
    }

    /// Whether the file is being read through without decompressing.
    ///
    /// `gzdirect` (`src/zlib.h:1726`, documented at `:1714-1725`) is true when
    /// the file is not in gzip format and the bytes are passed through unchanged,
    /// or when nothing has been read yet. `src/zlib.h:1721` is the one to
    /// remember: it is only meaningful *after* a read, so a caller checking it
    /// before reading gets the initial answer rather than an answer about the
    /// file.
    pub fn direct(self: *Gzip) bool {
        const gz = self.handle_ orelse return true;
        return c.gzdirect(gz) != 0;
    }

    /// Set the internal buffer size, returning the size actually used.
    ///
    /// `gzbuffer` (`src/zlib.h:1429`, documented at `:1421-1428`) rounds the
    /// request up to a power of two and returns what it got. **It has no effect
    /// once a read or a write has started** - the buffer exists by then - so this
    /// is a call to make immediately after opening, and the return value is the
    /// size to plan with.
    pub fn buffer(self: *Gzip, size: u32) Error!u32 {
        const gz = self.require();
        const got: c_int = c.gzbuffer(gz, size);
        if (got < 0) return error.MemError;
        return @intCast(got);
    }

    /// The last error, and the numeric code behind it, or null when there is
    /// none.
    ///
    /// `gzerror` (`src/zlib.h:1775`, documented at `:1768-1774`) returns a
    /// message the caller must **not free**: it points into the `gzFile`'s own
    /// state and stays valid only until the next `gz*` call on that file, or until
    /// the file is closed.
    ///
    /// So the message is a **borrow with a short life**, which is why this returns
    /// both halves in one struct and says so at the type. A caller that needs the
    /// text to outlive the next call must copy it, and a caller that needs it after
    /// `deinit` must read it before `deinit` - because `gzclose` is itself a
    /// `gz*` call, and the buffer it was pointing into is gone.
    ///
    /// Null means no error has been recorded, which is what `src/zlib.h:1772-1773`
    /// says a null return means.
    pub fn lastError(self: *Gzip) ?GzipError {
        const gz = self.handle_ orelse return null;
        var code: c_int = @intFromEnum(Status.ok);
        const raw = c.gzerror(gz, &code);
        const text = raw orelse return null;
        if (code == @intFromEnum(Status.ok)) return null;
        return .{ .message = std.mem.span(@as([*:0]const u8, @ptrCast(text))), .code = code };
    }

    /// Flush what is buffered to the file.
    ///
    /// `gzflush` (`src/zlib.h:1647`, documented at `:1636-1646`) returns `Z_OK`,
    /// `Z_BUF_ERROR` (not enough room for the flush) or `Z_ERRNO`.
    /// `sync_flush` and `full_flush` are the two that matter to a reader in another
    /// process; `finish` would end the stream.
    pub fn flush(self: *Gzip, mode: Flush) Error!void {
        const gz = self.require();
        try codeOrError(c.gzflush(gz, @intFromEnum(mode)));
    }

    /// Change the compression parameters used for later writes.
    ///
    /// `gzsetparams` (`src/zlib.h:1445`, documented at `:1436-1444`) returns
    /// `Z_OK`, `Z_STREAM_ERROR` (the file is not in write mode) or `Z_BUF_ERROR`
    /// (no room to apply the change, because compressed output is already
    /// pending). `src/zlib.h:1435` is the one that matters: this cannot be used
    /// once reading has begun.
    pub fn setParams(self: *Gzip, level: Level, strategy: Strategy) Error!void {
        const gz = self.require();
        try codeOrError(c.gzsetparams(gz, @intFromEnum(level), @intFromEnum(strategy)));
    }

    /// The handle, or a stop-the-program message naming what had none.
    ///
    /// Every `Gzip` method that passes a handle goes through this, so a
    /// `Gzip.empty` that was never opened says so instead of reaching the C with a
    /// null `gzFile`, which `src/gzguts.h` does not check for on most paths.
    fn require(self: *Gzip) *c.gzFile_s {
        return self.handle_ orelse @panic(
            "zlib: this Gzip owns no file; it was never opened, or deinit already " ++
                "closed it. Open a new one.",
        );
    }

    /// Ask the handle what its last error was, and report that rather than the
    /// guess the caller arrived with.
    ///
    /// `src/zlib.h:1484-1488` is the reason this exists: `gzread` answers `-1` for
    /// any error, and `gzerror` is where the code is. So a `-1` is not mapped to
    /// one invented failure - the handle is asked, and its answer is mapped. When
    /// the handle has nothing recorded, `fallback` is reported, because a failure
    /// with no recorded code is still a failure.
    fn reportedError(self: *Gzip, fallback: Error) Error {
        var code: c_int = @intFromEnum(Status.ok);
        const raw = c.gzerror(self.require(), &code);
        _ = raw;
        if (code == @intFromEnum(Status.ok)) return fallback;
        // `statusOf` already answers `error.UnknownStatus` for a code outside
        // the tag set, which is what this fallback then maps; spelling the same
        // test out here with `std.meta.intToEnum` repeated a removed API and the
        // range check with it.
        const status = statusOf(code) catch return fallback;
        return status.errorCode() orelse fallback;
    }
};

/// An error from the `gz*` layer: the message and the code behind it.
///
/// The message is a **borrow** into the `Gzip`'s own state and is valid until the
/// next `gz*` call on that file or until it is closed
/// (`src/zlib.h:1771-1773`). Copy it if it has to outlive that.
pub const GzipError = struct {
    /// Upstream's message. Never null, never free, short-lived.
    message: [:0]const u8,
    /// The numeric code, which `Status` names.
    code: c_int,
};

/// Where a `seek` counts from.
///
/// libc's `SEEK_SET`, `SEEK_CUR` and `SEEK_END`, which `src/zconf.h:511-514`
/// defines itself when `unistd.h` did not.
pub const SeekOrigin = enum(c_int) {
    /// From the beginning of the file.
    set = 0,
    /// From the current position.
    current = 1,
    /// From the end of the file.
    end = 2,
};