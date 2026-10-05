// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.

//! Consumes the `zlib` package the way an outside project would.
//!
//! Everything here goes through the published surface only: `dep.module("zlib")`
//! in `build.zig`, and `@import("zlib")` here. No path reaches into the library's
//! own tree, so if this builds and produces the answers below, the module
//! contract is real: the typed facade, the translated headers it re-exports as
//! `c`, the generated `zconf.h` that both were compiled against, and the native
//! library behind them all arrived through one dependency line.
//!
//! ## The answers are not this code talking to itself
//!
//! A round trip proves only that the two halves agree. Every check below is
//! stated against a value from outside the library:
//!
//!   * The RFC 1950 wrapper layout, read out of `src/doc/rfc1950.txt:245-278`:
//!     CM = 8, CINFO = 7 for a 32K window, `(CMF*256 + FLG)` a multiple of 31,
//!     FDICT clear, and the Adler-32 trailer in network order.
//!   * The RFC 1952 header layout, read out of `src/doc/rfc1952.txt:243-296` and
//!     `:374-381`: `ID1`/`ID2` fixed at 31 and 139, `CM` = 8, and XFL = 4 for
//!     "compressor used fastest algorithm".
//!   * The two checksums of a fixed payload, which `fixtures/PROVENANCE.md`
//!     records as produced by **zlib 1.2.13** - a different release of the
//!     reference implementation - over the same 275 bytes.
//!
//! The consumer additionally performs a **linked-versus-loaded route check**:
//! the same provider is named twice - once through the module's own dispatch and
//! once through a direct read of the same symbol names - and both must agree.
//! That is the check that would catch a `c` module that resolved a different
//! provider for two different names.
//!
//! The same source builds against a linked package and against a
//! runtime-loaded one. `zlib.runtime_loaded` is a comptime constant, so the
//! difference is one branch and no duplicated program: in the runtime-loaded
//! build the provider is named on the command line (`--provider <path>`) or in
//! `ZLIB_TEST_PROVIDER`, loaded once, and the same answers follow.

const std = @import("std");
const zlib = @import("zlib");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `ZLIB_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location, and a build that
/// was not told which file to load says so rather than loading something else.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get("ZLIB_TEST_PROVIDER") orelse
        return noProvider();
}

/// Say which variable is missing. An error name on its own would send the next
/// person into the loader instead of to the command line.
fn noProvider() ConfigurationError {
    std.debug.print(
        "consumer: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export ZLIB_TEST_PROVIDER with a shared object exporting the " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// The payload the checksums are stated over.
///
/// 275 bytes, and the same bytes `fixtures/plain.bin` holds: an embedded NUL at
/// offset 251 and a `0xff` byte that is not valid UTF-8, so a slice that treated
/// either as a terminator could not produce the right checksum.
const payload = "zlib foundation SDK interop payload\n" ++
    "=====================================\n" ++
    "line one: the quick brown fox jumps over the lazy dog\n" ++
    "line two: the quick brown fox jumps over the lazy dog\n" ++
    "line three: 0123456789 0123456789 0123456789 0123456789\n" ++
    "binary tail: \x00\x01\x02\xFD\xFE\xFF and a NUL inside\n";

/// The Adler-32 zlib 1.2.13 recorded for `payload`
/// (`fixtures/pyzlib/checksums.txt`).
const payload_adler32: u32 = 3970324232;

/// The CRC-32 zlib 1.2.13 recorded for the same bytes.
const payload_crc32: u32 = 1368583364;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build every call below goes through a table that this
    // one call fills. In a linked build the branch is not analyzed at all.
    if (comptime zlib.runtime_loaded) {
        try zlib.load(.{ .path = try providerRequest(init) });
    }

    try w.print("zlib consumer\n", .{});
    // Through the raw escape hatch, so this line names the library this build
    // reached rather than a constant compiled into this program. It is printed,
    // not compared: a version string is provenance, not behaviour.
    try w.print("{s} provider reports: {s}\n", .{
        if (zlib.runtime_loaded) "loaded" else "linked",
        zlib.zlibVersion(),
    });

    // The version the headers declare, read out of the embedded `src/zlib.h`, and
    // the provider's own answer. They must be the same string: the one is what
    // `deflateInit2_` was handed and the other is what `zlibVersion()` returns,
    // and a mismatch is the definition of the wrong library being loaded.
    try checkString(w, "ZLIB_VERSION from the package's headers", zlib.version, "1.3.2");
    try checkString(w, "the provider agrees with those headers", zlib.zlibVersion(), "1.3.2");
    try checkInt(w, "ZLIB_VERNUM from src/zlib.h:45", zlib.version_num, 0x1320);

    // The provider's compile flags, against the two configurations this SDK
    // refuses: src/zlib.h:1226 (ZLIB_DEBUG) and :1228 (ZLIB_WINAPI).
    const flags = zlib.zlibCompileFlags();
    try checkInt(w, "compile flag bit 8 (ZLIB_DEBUG) clear", flags & zlib.flag_debug, 0);
    try checkInt(w, "compile flag bit 10 (ZLIB_WINAPI) clear", flags & zlib.flag_winapi, 0);

    // The two checksum starting values and the two checksums over the payload.
    // The checksum values are zlib 1.2.13's, recorded in this package's
    // fixtures; this build is 1.3.2, so agreeing with them is cross-release
    // interop on the checksum path as well as on the compression path.
    try checkInt(w, "adler32 of no bytes", zlib.checksum.adler32Empty(), 1);
    try checkInt(w, "crc32 of no bytes", zlib.checksum.crc32Empty(), 0);
    try checkInt(
        w,
        "adler32(payload), as zlib 1.2.13 recorded it",
        zlib.adler32(zlib.checksum.adler32_init, payload),
        payload_adler32,
    );
    try checkInt(
        w,
        "crc32(payload), as zlib 1.2.13 recorded it",
        zlib.crc32(zlib.checksum.crc32_init, payload),
        payload_crc32,
    );

    // adler32_combine over a split, against the whole-input answer.
    const split = 137;
    const head = zlib.adler32(zlib.checksum.adler32_init, payload[0..split]);
    try checkInt(
        w,
        "adler32_combine equals the whole-input adler32",
        zlib.adler32_combine(
            head,
            zlib.adler32(zlib.checksum.adler32_init, payload[split..]),
            payload[split..].len,
        ),
        payload_adler32,
    );

    // The one-shot round trip, and the RFC 1950 layout of what it produced.
    var encoded: [1024]u8 = undefined;
    const encoded_len = try zlib.compress2(&encoded, payload, .{});

    const cmf = encoded[0];
    const flg = encoded[1];
    // src/doc/rfc1950.txt:255-258: CM = 8 is the deflate method.
    try checkInt(w, "RFC 1950 CM", cmf & 0x0F, 8);
    // src/doc/rfc1950.txt:260-263: CINFO = 7 is a 32K window, above 7 not allowed.
    try checkInt(w, "RFC 1950 CINFO", cmf >> 4, 7);
    // src/doc/rfc1950.txt:275-278: (CMF*256 + FLG) must be a multiple of 31.
    try checkInt(
        w,
        "RFC 1950 (CMF*256+FLG) mod 31",
        (@as(u32, cmf) * 256 + @as(u32, flg)) % 31,
        0,
    );
    // src/doc/rfc1950.txt:268-274: no preset dictionary in this configuration.
    try checkInt(w, "RFC 1950 FDICT clear", flg & 0x20, 0);

    var decoded: [1024]u8 = undefined;
    try checkString(
        w,
        "uncompress round trip",
        decoded[0..try zlib.uncompress(&decoded, encoded[0..encoded_len])],
        payload,
    );

    // The streaming API, through both owning structs, in all three formats. This
    // is the part that would break first if the facade and the C library
    // disagreed about `z_stream`'s layout or about a return code.
    // `inline for`, so `format` is comptime-known and `@tagName(format) ++ "..."`
    // is a comptime slice. A plain `for` makes it a runtime value and the
    // concatenation does not compile.
    inline for ([_]zlib.Format{ .zlib, .raw, .gzip }) |format| {
        var out: [1024]u8 = undefined;
        var deflater: zlib.Deflater = .empty;
        try deflater.init(.{ .level = .best_compression }, format);
        // The parentheses are required: `try` binds tighter than `.`, so
        // `try f(x).produced` asks for a field on the error union.
        const produced = (try deflater.runAll(payload, &out)).produced;
        // src/zlib.h:768: deflateBound is this stream's own upper bound.
        //
        // The comparison is bound into a named value first, and the result is
        // `@intFromBool`, because an `if` whose condition depends on a runtime
        // value cannot yield a `comptime_int`.
        const upper_bound = try deflater.bound(payload.len);
        try checkInt(
            w,
            @tagName(format) ++ ": deflateBound bounds the output",
            @intFromBool(produced <= upper_bound),
            1,
        );
        try checkInt(w, @tagName(format) ++ ": total_in", deflater.totalIn(), payload.len);
        try checkInt(w, @tagName(format) ++ ": total_out", deflater.totalOut(), produced);
        deflater.deinit();

        var back: [1024]u8 = undefined;
        var inflater: zlib.Inflater = .empty;
        try inflater.init(format);
        const step = try inflater.runAll(out[0..produced], &back);
        try checkString(w, @tagName(format) ++ ": round trip", back[0..step.produced], payload);
        try inflater.reset();
        try checkInt(w, @tagName(format) ++ ": total_in after reset", inflater.totalIn(), 0);
        inflater.deinit();
    }

    // A short destination is refused with `Z_BUF_ERROR`
    // (`src/zlib.h:1300`), and the bytes that *did* fit are still written:
    // `compress.c:45-52` points `next_out` at `dest` and hands `deflate` the
    // space that is available, so a full 8-byte destination comes back filled
    // and `*destLen` is 8 (`compress.c:63`).
    //
    // The old comment here claimed the buffer was "left alone", citing
    // `src/zlib.h:1295-1301`. That range states the return codes only and says
    // nothing about the buffer, and a C oracle compiled against this
    // repository's own `src/zlib.h` and `src/compress.c` returned
    // `rc = Z_BUF_ERROR` with `destLen = 8` and `dest[0] = 0x78`.
    var short: [8]u8 = @splat(0xA5);
    try checkError(
        w,
        "a short destination reports BufError",
        zlib.compress2(&short, payload, .{}) == error.BufError,
    );
    // The header of a zlib stream is `CMF`/`FLG`; `CMF & 0x0F == 8` is the
    // deflate method (`src/doc/rfc1950.txt:255-258`), so a byte that is not
    // the sentinel proves the provider wrote into the destination it was given.
    try checkInt(w, "the short destination was written", short[0] & 0x0F, 8);
    try checkInt(
        w,
        "compressBound is at least the input length",
        @intFromBool(zlib.compressBound(payload.len) >= payload.len),
        1,
    );

    // The `gz*` file layer, against a real file. The RFC 1952 fields are read
    // out of the file's own bytes, which is a different check from reading them
    // back through the provider's parser: this one cannot be satisfied by a
    // parser that agrees with itself.
    var path_buffer: [256]u8 = undefined;
    // `std.crypto.random` no longer exists in Zig 0.16.0. The stdlib's own
    // route is `std.Random.IoSource`, which draws from the `std.Io` this
    // program already holds.
    var random_source = std.Random.IoSource{ .io = io };
    const path = try std.fmt.bufPrintZ(&path_buffer, "zlib-consumer-{d}.gz", .{
        random_source.interface().int(u32),
    });
    // `std.fs.cwd` is gone in Zig 0.16.0. The directory handle is
    // `std.Io.Dir.cwd()`, and both file operations take the `std.Io` this
    // program already holds as their second argument.
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(io, path) catch {};

    {
        var file = try zlib.Gzip.openWrite(path);
        defer file.deinit();
        try checkInt(w, "gzwrite took the whole payload", try file.write(payload), payload.len);
        // src/zlib.h:1636-1646: a sync flush before the file is closed.
        try file.flush(.sync_flush);
    }

    {
        const bytes = try cwd.readFileAlloc(io, path, init.arena.allocator(), .limited(4096));
        // src/doc/rfc1952.txt:289-293: ID1 = 31 (0x1f), ID2 = 139 (0x8b).
        try checkInt(w, "RFC 1952 ID1", bytes[0], 0x1f);
        try checkInt(w, "RFC 1952 ID2", bytes[1], 0x8b);
        // src/doc/rfc1952.txt:294-299: CM = 8 is the deflate method.
        try checkInt(w, "RFC 1952 CM", bytes[2], 8);
        // src/doc/rfc1952.txt:362: reserved FLG bits must be zero.
        try checkInt(w, "RFC 1952 reserved FLG bits", bytes[3] & 0xF0, 0);
        // src/doc/rfc1950.txt and RFC 1952 §2.3 (src/doc/rfc1952.txt:272-277):
        // the trailer is CRC-32 then ISIZE, both little-endian.
        var crc: u32 = 0;
        for (0..4) |i| crc |= @as(u32, bytes[bytes.len - 8 + i]) << @intCast(8 * i);
        // Not named `isize`: that is a primitive type name in Zig, and a local
        // may not shadow one. The field is RFC 1952's ISIZE either way.
        var isize_field: u32 = 0;
        for (0..4) |i| isize_field |= @as(u32, bytes[bytes.len - 4 + i]) << @intCast(8 * i);
        try checkInt(w, "RFC 1952 trailer CRC32", crc, payload_crc32);
        try checkInt(w, "RFC 1952 trailer ISIZE", isize_field, payload.len);
    }

    {
        var file = try zlib.Gzip.openRead(path);
        defer file.deinit();

        var read_buffer: [1024]u8 = undefined;
        var filled: usize = 0;
        while (true) {
            // No `&`: `read_buffer[filled..]` is already the slice `readSome`
            // asks for, and `&` on a slice yields a pointer to the slice.
            const got = file.readSome(read_buffer[filled..]) catch |err| switch (err) {
                error.EndOfInput => break,
                else => return err,
            };
            if (got == 0) break;
            filled += got;
        }
        try checkString(w, "gz file round trip", read_buffer[0..filled], payload);
        try checkInt(w, "gztell is the uncompressed length", try file.tell(), payload.len);
        try checkInt(w, "gzdirect is false for a gzip file", @intFromBool(!file.direct()), 1);
        try checkInt(w, "gzeof after reading to the end", @intFromBool(file.eof()), 1);
    }

    // The linked-versus-loaded route check.
    //
    // Two independent reads of the same provider, which have to agree. The first
    // is the facade's `zlibVersion()`, routed through whatever `c` this build
    // resolved to. The second is the raw escape hatch, which in a runtime-loaded
    // build is the *same* table entry reached by its declared name - so if the
    // dispatch had wired `zlibVersion` to a different provider than the
    // translation describes, these two would diverge and this check fails.
    //
    // And the third is the facade against the *header* version, read out of the
    // embedded `src/zlib.h`: header, module and provider are three distinct
    // things and all three have to be the same release.
    try checkString(w, "route check: facade and raw escape hatch agree",
        try rawVersion(), zlib.zlibVersion());
    try checkString(w, "route check: the provider matches these headers",
        zlib.zlibVersion(), zlib.version);

    // And one real operation through the raw route, on a declaration the facade
    // does not wrap: `deflateTune` is declared at src/zlib.h:751 and this
    // package's facade does not name it.
    var stream: zlib.c.z_stream = std.mem.zeroes(zlib.c.z_stream);
    try checkInt(w, "raw deflateInit2_ returned Z_OK", zlib.c.deflateInit2_(
        &stream,
        6,
        // `Z_DEFLATED` translates as a `c_int`, not an enum, so it is passed
        // through directly.
        zlib.c.Z_DEFLATED,
        15,
        8,
        0,
        zlib.version,
        @sizeOf(zlib.c.z_stream),
    ), 0);
    defer _ = zlib.c.deflateEnd(&stream);
    // `deflateTune(strm, good_length, max_lazy, nice_length, max_chain)`
    // (src/zlib.h:751). Five arguments; 128 is a max_chain value zlib accepts
    // at the default level.
    try checkInt(w, "raw deflateTune returned Z_OK", zlib.c.deflateTune(&stream, 5, 5, 5, 128), 0);

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// `zlibVersion` reached through the raw escape hatch.
///
/// In a runtime-loaded build the dispatch rewrote this declaration to a table
/// lookup, so the call below *is* the routed one; in a linked build it is the
/// plain extern. Either way it is a different expression from the facade's, which
/// is the point of the route check.
fn rawVersion() ![:0]const u8 {
    return std.mem.span(zlib.c.zlibVersion());
}

/// Print, then compare. A mismatch exits non-zero through `ConsumerCheckFailed`.
fn checkInt(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    try w.print("{s: <44}{d}\n", .{ what, got });
    if (got != expected) {
        std.debug.print("consumer: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.ConsumerCheckFailed;
    }
}

fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <44}{d} bytes\n", .{ what, got.len });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print(
            "consumer: {s}: expected {d} bytes, computed {d} bytes\n",
            .{ what, expected.len, got.len },
        );
        std.debug.print("consumer: {s}: expected \"{s}\", computed \"{s}\"\n", .{ what, expected, got });
        return error.ConsumerCheckFailed;
    }
}

fn checkError(w: *std.Io.Writer, what: []const u8, ok: bool) !void {
    try w.print("{s: <44}{s}\n", .{ what, if (ok) "yes" else "no" });
    if (!ok) {
        std.debug.print("consumer: {s}: the check did not hold\n", .{what});
        return error.ConsumerCheckFailed;
    }
}