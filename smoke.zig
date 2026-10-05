// SPDX-License-Identifier: zlib
// See FORK-LICENSE.md for what that identifier covers.

//! A runnable, deterministic demonstration of the zlib facade.
//!
//! `zig build smoke` runs this. There is no input to supply and no output that
//! depends on the host, the clock or a random seed, so the same lines come out
//! every time.
//!
//! Every answer below is an expected value, not a value this program computed
//! and printed for comparison. They come from three places outside this package:
//! the RFCs vendored under `src/doc/`, the fixtures `fixtures/PROVENANCE.md`
//! records with their producers, and the on-disk facts the `gz*` file layer is
//! asked to report about a file it just wrote. A mismatch prints both sides and
//! exits non-zero, so this is a check and not a demo.
//!
//! In a runtime-loading build the provider is named on the command line
//! (`--provider <path>`) or in `ZLIB_TEST_PROVIDER`, and the program says which
//! configuration it is in the first two lines. In a linked build neither is
//! needed and neither is read.
//!
//! What it exercises, in order: the provider's own version and compile flags; the
//! Adler-32 and CRC-32 starting values; the two checksums of a known payload;
//! RFC 1950's wrapper layout on a stream this build wrote; a round trip through
//! all three formats; the streaming API's counters and `deflateBound`; a gzip
//! member written to a real file and read back with the header fields the RFC
//! gives them; and the raw translated route for a declaration the facade does not
//! wrap.

const std = @import("std");
const zlib = @import("zlib");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `ZLIB_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location or falls back to
/// a linked copy: a runtime-loading build that was not told which file to load
/// reports that it was not told, rather than loading something else.
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
        "smoke: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export ZLIB_TEST_PROVIDER with a shared object exporting the " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// The payload every check below agrees on.
///
/// It is the same 275 bytes the fixtures encode, written out here rather than
/// embedded, because a runnable demonstration that reads a build input would not
/// be a demonstration of the library. The two checksums of these bytes are
/// stated as literals rather than computed, and `fixtures/pyzlib/checksums.txt`
/// records the same two values as produced by zlib 1.2.13 - an independent
/// implementation, at a different release, over the same input.
/// The bytes are `0x00 0x01 0x02 0xfd 0xfe 0xff`: a run of low bytes, a run of
/// high bytes, and an embedded NUL at offset 251. The NUL is the point. A Zig
/// slice carries its length, so a payload with a NUL in it exercises the whole
/// difference between a slice and a C string - and the `0xff` byte is data that
/// is not valid UTF-8, on a path that never looks at encoding.
const payload = "zlib foundation SDK interop payload\n" ++
    "=====================================\n" ++
    "line one: the quick brown fox jumps over the lazy dog\n" ++
    "line two: the quick brown fox jumps over the lazy dog\n" ++
    "line three: 0123456789 0123456789 0123456789 0123456789\n" ++
    "binary tail: \x00\x01\x02\xFD\xFE\xFF and a NUL inside\n";

/// What zlib 1.2.13 recorded for these bytes (`fixtures/pyzlib/checksums.txt`).
const payload_adler32: u32 = 3970324232;

/// What zlib 1.2.13 recorded for these bytes, the same file.
const payload_crc32: u32 = 1368583364;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build nothing below can run until a provider is
    // loaded, and the load is the one explicit step the contract asks for. In a
    // linked build this is a no-op at comptime and the module is already usable.
    if (comptime zlib.runtime_loaded) {
        try zlib.load(.{ .path = try providerRequest(init) });
    }

    try w.print("zlib smoke\n", .{});
    // Through the raw escape hatch, so this line names the provider this build
    // reached rather than a constant compiled into this program. It is printed,
    // not compared: a version string is provenance, not behaviour.
    try w.print("{s} provider reports: {s}\n", .{
        if (zlib.runtime_loaded) "loaded" else "linked",
        zlib.zlibVersion(),
    });
    try w.flush();

    // The version the *headers* declare, read out of the embedded `src/zlib.h`
    // rather than written here, and the packed number beside it.
    try checkString(w, "ZLIB_VERSION from src/zlib.h:44", zlib.version, "1.3.2");
    try checkInt(w, "ZLIB_VERNUM from src/zlib.h:45", zlib.version_num, 0x1320);

    // The provider's compile flags, against the two configurations this SDK
    // refuses: src/zlib.h:1226 (ZLIB_DEBUG) and src/zlib.h:1228 (ZLIB_WINAPI).
    const flags = zlib.zlibCompileFlags();
    try checkInt(w, "compile flag bit 8 (ZLIB_DEBUG) clear", flags & zlib.flag_debug, 0);
    try checkInt(w, "compile flag bit 10 (ZLIB_WINAPI) clear", flags & zlib.flag_winapi, 0);
    // src/zlib.h:1218-1223: two bits for the size of uInt, two for uLong, with
    // 00 = 16 bits, 01 = 32, 10 = 64 and 11 = "other". `src/zutil.c:35-40` is
    // the switch that writes them, so the expected code is that switch applied
    // to the width the *headers* declare - which is the whole point of the
    // check: a constant here could only ever prove that this program and this
    // library were compiled for the same host, and would say nothing at all
    // about the two disagreeing.
    try checkInt(
        w,
        "sizeof(uInt) code from zlibCompileFlags",
        (flags >> 0) & 0x3,
        uIntWidthCode(),
    );

    // The two checksum starting values, from src/doc/rfc1950.txt:485-490 for
    // Adler-32 and the CRC-32 of no bytes for the other.
    try checkInt(w, "adler32 of no bytes", zlib.checksum.adler32Empty(), 1);
    try checkInt(w, "crc32 of no bytes", zlib.checksum.crc32Empty(), 0);

    // The checksums of a payload another implementation already checksummed.
    try checkInt(
        w,
        "adler32(payload) as zlib 1.2.13 recorded it",
        zlib.adler32(zlib.checksum.adler32_init, payload),
        payload_adler32,
    );
    try checkInt(
        w,
        "crc32(payload) as zlib 1.2.13 recorded it",
        zlib.crc32(zlib.checksum.crc32_init, payload),
        payload_crc32,
    );

    // A running checksum continued from a previous result must equal hashing the
    // whole thing: that is what makes it a running checksum.
    const split = 137;
    const first_adler = zlib.adler32(zlib.checksum.adler32_init, payload[0..split]);
    try checkInt(
        w,
        "adler32 continued equals whole-input adler32",
        zlib.adler32(first_adler, payload[split..]),
        payload_adler32,
    );

    // adler32_combine over the same split, against the whole-input answer.
    try checkInt(
        w,
        "adler32_combine equals whole-input adler32",
        zlib.adler32_combine(
            first_adler,
            zlib.adler32(zlib.checksum.adler32_init, payload[split..]),
            payload[split..].len,
        ),
        payload_adler32,
    );

    // The RFC 1950 wrapper this build wrote, checked against the layout in
    // src/doc/rfc1950.txt:245-278 before anything is decompressed.
    var zlib_stream: [512]u8 = undefined;
    const zlib_len = try zlib.compress2(&zlib_stream, payload, .{});

    const cmf = zlib_stream[0];
    const flg = zlib_stream[1];
    // src/doc/rfc1950.txt:255-258: CM = 8 is the deflate method.
    try checkInt(w, "RFC 1950 CM", cmf & 0x0F, 8);
    // src/doc/rfc1950.txt:260-263: CINFO = 7 is a 32K window, and above 7 is
    // not allowed.
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
    // The Adler-32 trailer, in the most-significant-byte-first order
    // src/doc/rfc1950.txt:318-334 specifies.
    var trailer: u32 = 0;
    for (zlib_stream[zlib_len - 4 .. zlib_len]) |byte| trailer = (trailer << 8) | byte;
    try checkInt(w, "RFC 1950 ADLER32 trailer", trailer, payload_adler32);

    // Decompress it through the two one-shot routes, and through the streaming
    // pair, which is a different implementation path inside the library.
    var back: [1024]u8 = undefined;
    try checkString(
        w,
        "uncompress round trip",
        back[0..try zlib.uncompress(&back, zlib_stream[0..zlib_len])],
        payload,
    );
    // `uncompress2` takes the source by pointer so it can advance it past what
    // it consumed (`src/zlib.h:1339-1343`), which is the whole difference
    // between it and `uncompress`.
    var zlib_stream_rest: []const u8 = zlib_stream[0..zlib_len];
    try checkString(
        w,
        "compress then uncompress2",
        back[0..try zlib.uncompress2(&back, &zlib_stream_rest)],
        payload,
    );

    // Every format round-trips, and the raw one is the same deflate body without
    // a wrapper - which is what src/zlib.h:236-241's negative windowBits means.
    // `inline` because `@tagName(format) ++ ...` below concatenates at comptime,
    // and a runtime loop variable cannot.
    inline for ([_]zlib.Format{ .zlib, .raw, .gzip }) |format| {
        var encoded: [1024]u8 = undefined;
        var deflater: zlib.Deflater = .empty;
        try deflater.init(.{}, format);
        const produced = (try deflater.runAll(payload, &encoded)).produced;
        // A bound, so the comparison is against it and not for equality with it:
        // `src/zlib.h:768-770` is an upper bound, and the output is smaller than
        // that by whatever the compressor saved.
        try checkInt(
            w,
            @tagName(format) ++ ": deflateBound bounds the output",
            if (produced <= try deflater.bound(payload.len)) @as(u64, 1) else @as(u64, 0),
            1,
        );
        // src/zlib.h:93 and :95: the running totals the stream itself keeps.
        try checkInt(w, @tagName(format) ++ ": total_in", deflater.totalIn(), payload.len);
        try checkInt(w, @tagName(format) ++ ": total_out", deflater.totalOut(), produced);
        deflater.deinit();

        var inflater: zlib.Inflater = .empty;
        try inflater.init(format);
        var decoded: [1024]u8 = undefined;
        const step = try inflater.runAll(encoded[0..produced], &decoded);
        try checkString(w, @tagName(format) ++ ": round trip", decoded[0..step.produced], payload);
        // The stream is reusable without a new init: src/zlib.h:979-984.
        try inflater.reset();
        try checkInt(w, @tagName(format) ++ ": total_in after reset", inflater.totalIn(), 0);
        inflater.deinit();
    }

    // A short destination is refused, per src/zlib.h:1298-1301, and
    // compressBound says how big to retry. The buffer is *not* left alone:
    // `src/compress.c:50-59` hands `deflate` whatever room is left and only
    // finds out there is none when `left` reaches zero, so what lands in the
    // short buffer is the leading part of the very stream a correctly-sized call
    // produces. This line used to assert the opposite.
    const sentinel: u8 = 0xA5;
    var short: [8]u8 = @splat(sentinel);
    const refused = zlib.compress2(&short, payload, .{});
    try checkError(w, "a short destination reports BufError", refused == error.BufError);
    try checkInt(
        w,
        "the short buffer was written",
        if (short[0] == sentinel) @as(u64, 0) else @as(u64, 1),
        1,
    );
    {
        var roomy: [512]u8 = undefined;
        const whole = try zlib.compress2(roomy[0..zlib.compressBound(payload.len)], payload, .{});
        try checkError(w, "the short buffer holds a prefix of the real stream", std.mem.eql(u8, short[0..], roomy[0..short.len]));
        try checkInt(w, "the real stream is longer than the short buffer", if (whole > short.len) @as(u64, 1) else @as(u64, 0), 1);
    }

    // The `gz*` file layer, against a real file this program wrote: the header
    // fields RFC 1952 §2.3.1 gives them, read back through the provider's own
    // parser rather than by hand.
    var path_buffer: [256]u8 = undefined;
    // `std.crypto.random` and `std.c.rand` are both gone in this compiler, and
    // this name needs no generator: the process is the only writer, it reads
    // back exactly what it wrote, and the file is removed on the way out. The
    // process id is the whole of the uniqueness that is needed, and `runTag`
    // is where it comes from on each target.
    const path = try std.fmt.bufPrintZ(&path_buffer, "zlib-smoke-{d}.gz", .{runTag()});
    // The `Dir` is `std.Io.Dir.cwd()` in this compiler and every operation on it
    // takes the `Io` separately.
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var file = try zlib.Gzip.openWrite(path);
        defer file.deinit();
        try checkInt(w, "gzwrite took the whole payload", try file.write(payload), payload.len);
        // src/zlib.h:1436-1444: gzsetparams before reading has begun.
        try file.flush(.sync_flush);
    }

    {
        var file = try zlib.Gzip.openRead(path);
        defer file.deinit();

        var read_buffer: [1024]u8 = undefined;
        var filled: usize = 0;
        while (true) {
            // A named slice, not `&read_buffer[filled..]`: `&` on a slice is a
            // `*[]u8`, and `readSome` takes the slice.
            const room: []u8 = read_buffer[filled..];
            const got = file.readSome(room) catch |err| switch (err) {
                error.EndOfInput => break,
                else => return err,
            };
            if (got == 0) break;
            filled += got;
        }
        try checkString(w, "gz file round trip", read_buffer[0..filled], payload);
        try checkInt(w, "gztell is the uncompressed length", try file.tell(), payload.len);
        try checkInt(w, "gzoffset is positive", if (try file.offset() > 0) @as(u64, 1) else @as(u64, 0), 1);
        try checkInt(w, "gzdirect is false for a gzip file", if (file.direct()) @as(u64, 1) else @as(u64, 0), 0);
        try checkInt(w, "gzeof after reading to the end", if (file.eof()) @as(u64, 1) else @as(u64, 0), 1);
    }

    // The gzip member header, read through `readHeader` rather than by hand.
    // `src/zlib.h:1073-1075` puts the registration before the first `inflate`
    // and says the fields are filled during it, so a member is built here and
    // decoded first; the header is then read out of the buffer, not returned
    // by the call that registered it.
    var header_buffers: zlib.HeaderBuffer = .{};
    {
        var member: [1024]u8 = undefined;
        var deflater: zlib.Deflater = .empty;
        try deflater.init(.{ .level = .best_compression }, .gzip);
        defer deflater.deinit();
        const member_len = (try deflater.runAll(payload, &member)).produced;

        var inflater: zlib.Inflater = .empty;
        try inflater.init(.gzip);
        defer inflater.deinit();
        try inflater.readHeader(&header_buffers);

        var decoded: [4096]u8 = undefined;
        const step = try inflater.runAll(member[0..member_len], &decoded);
        try checkInt(w, "gzip member decodes to the payload length", step.produced, payload.len);
        try checkString(w, "gzip member decodes to the payload", decoded[0..step.produced], payload);

        const header = header_buffers.current();
        // src/doc/rfc1952.txt:383: OS is the byte `src/deflate.c` writes from
        // `OS_CODE`, which is 3 on Unix.
        try checkInt(w, "gzip OS byte is 3 (Unix)", header.os, 3);
        // src/deflate.c writes XFL = 2 at level 9, which src/doc/rfc1952.txt:379-380
        // reads as "compressor used maximum compression".
        try checkInt(w, "gzip XFL byte is 2 at level 9", header.xflags, 2);
        // src/doc/rfc1952.txt:364-372: no timestamp is available for a member
        // written here.
        try checkInt(w, "gzip MTIME is 0 for a member this program wrote", header.time, 0);
        // src/zlib.h:1076-1078: `done` is what says the header was completed.
        try checkError(w, "gzip header reported done", header.done);
        // This program never set FNAME, so zlib's writer put none in:
        // src/doc/rfc1952.txt:353-356 gives FNAME for a member compressed from
        // a named file, and this one was not.
        try checkError(w, "no FNAME in a member this program wrote", header.nameSlice() == null);
    }

    // zError's own table, src/zutil.c:13-24, through the public entry point.
    try checkString(w, "zError(Z_DATA_ERROR)", zlib.zError(-3), "data error");
    try checkString(w, "zError(Z_STREAM_END)", zlib.zError(1), "stream end");

    // The raw translated route: `get_crc_table` is declared at src/zlib.h:2035
    // and this facade does not wrap it, so reaching it proves the escape hatch is
    // a real one.
    const table = zlib.c.get_crc_table();
    try checkError(w, "get_crc_table returned a table", table != null);

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// The two-bit code `src/zutil.c:35-40` writes for `sizeof(uInt)`: 0 for 16
/// bits, 1 for 32, 2 for 64 and 3 for anything else. Applied to the width the
/// translated headers declare, so this compares the compiled C against the
/// header rather than pinning one number.
fn uIntWidthCode() u32 {
    return switch (@sizeOf(zlib.c.uInt)) {
        2 => 0,
        4 => 1,
        8 => 2,
        else => 3,
    };
}

/// A number that tells two runs of this smoke apart in one directory.
///
/// `std.c.getpid` is the obvious answer and it is right on POSIX, but
/// `std.c.pid_t` is `std.os.windows.HANDLE` on Windows - that is,
/// `*anyopaque` - because a process handle is what `getpid` returns there
/// (`std/c.zig:4288-4294`). So the value is a number on one target and an opaque
/// pointer on the other, and it is named per target rather than formatted
/// through `{d}` and left to fail on the cell that is compiled but never run.
fn runTag() u64 {
    return switch (@import("builtin").os.tag) {
        .windows => @as(u64, std.os.windows.GetCurrentProcessId()),
        else => @intCast(std.c.getpid()),
    };
}

/// Print, then compare. A mismatch exits non-zero through `SmokeCheckFailed`, so
/// this is a check and not a report.
fn checkInt(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    try w.print("{s: <44}{d}\n", .{ what, got });
    if (got != expected) {
        std.debug.print("zlib: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.SmokeCheckFailed;
    }
}

fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <44}{d} bytes\n", .{ what, got.len });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print(
            "zlib: {s}: expected {d} bytes, computed {d} bytes\n",
            .{ what, expected.len, got.len },
        );
        std.debug.print("zlib: {s}: expected \"{s}\", computed \"{s}\"\n", .{ what, expected, got });
        return error.SmokeCheckFailed;
    }
}

fn checkError(w: *std.Io.Writer, what: []const u8, ok: bool) !void {
    try w.print("{s: <44}{s}\n", .{ what, if (ok) "yes" else "no" });
    if (!ok) {
        std.debug.print("zlib: {s}: the check did not hold\n", .{what});
        return error.SmokeCheckFailed;
    }
}