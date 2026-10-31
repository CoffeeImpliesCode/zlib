// SPDX-License-Identifier: zlib
// See FORK-LICENSE.md for what that identifier covers.

//! Deterministic facade checks use RFC values, recorded fixtures, and provider/file results.
//! Checks cover checksums, formats, streaming, gzip files, and raw C access; mismatches exit non-zero.
//! Fixture producer versions and digests are recorded in fixtures/PROVENANCE.md.
//! Runtime builds require an explicit provider path; linked builds need none.

const std = @import("std");
const zlib = @import("zlib");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// Resolves the provider from `--provider <path>` or `ZLIB_TEST_PROVIDER`.
/// Runtime builds do not search defaults or fall back to a linked library.
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

/// Reports that no runtime provider was configured.
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

/// Fixed 275-byte payload used by every check; checksums match zlib 1.2.13.
/// Contains a NUL at offset 251 and non-UTF-8 bytes; checks use its slice length.
const payload = "zlib foundation SDK interop payload\n" ++
    "=====================================\n" ++
    "line one: the quick brown fox jumps over the lazy dog\n" ++
    "line two: the quick brown fox jumps over the lazy dog\n" ++
    "line three: 0123456789 0123456789 0123456789 0123456789\n" ++
    "binary tail: \x00\x01\x02\xFD\xFE\xFF and a NUL inside\n";

/// Adler-32 recorded by zlib 1.2.13 for `payload`.
const payload_adler32: u32 = 3970324232;

/// CRC-32 recorded by zlib 1.2.13 for `payload`.
const payload_crc32: u32 = 1368583364;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // Runtime builds load the requested provider; linked builds need no explicit load.
    if (comptime zlib.runtime_loaded) {
        try zlib.load(.{ .path = try providerRequest(init) });
    }

    try w.print("zlib smoke\n", .{});
    // Report the version returned by the selected provider.
    try w.print("{s} provider reports: {s}\n", .{
        if (zlib.runtime_loaded) "loaded" else "linked",
        zlib.zlibVersion(),
    });
    try w.flush();

    // Read the declared version from the embedded header.
    try checkString(w, "ZLIB_VERSION from src/zlib.h:44", zlib.version, "1.3.2");
    try checkInt(w, "ZLIB_VERNUM from src/zlib.h:45", zlib.version_num, 0x1320);

    // Check the provider's debug and WinAPI configuration flags.
    const flags = zlib.zlibCompileFlags();
    try checkInt(w, "compile flag bit 8 (ZLIB_DEBUG) clear", flags & zlib.flag_debug, 0);
    try checkInt(w, "compile flag bit 10 (ZLIB_WINAPI) clear", flags & zlib.flag_winapi, 0);
    // `zlibCompileFlags` stores `uInt` width in bits 0–1.
    // Derive the expected code from the translated header, not the host.
    try checkInt(
        w,
        "sizeof(uInt) code from zlibCompileFlags",
        (flags >> 0) & 0x3,
        uIntWidthCode(),
    );

    // Adler-32 starts at 1; CRC-32 of empty input is zero.
    try checkInt(w, "adler32 of no bytes", zlib.checksum.adler32Empty(), 1);
    try checkInt(w, "crc32 of no bytes", zlib.checksum.crc32Empty(), 0);

    // Compare checksums with values recorded by another implementation.
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

    // Continuing a checksum must match hashing the entire payload.
    const split = 137;
    const first_adler = zlib.adler32(zlib.checksum.adler32_init, payload[0..split]);
    try checkInt(
        w,
        "adler32 continued equals whole-input adler32",
        zlib.adler32(first_adler, payload[split..]),
        payload_adler32,
    );

    // Compare `adler32_combine` with the whole-input result.
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

    // Check the written zlib wrapper against RFC 1950 before decoding.
    var zlib_stream: [512]u8 = undefined;
    const zlib_len = try zlib.compress2(&zlib_stream, payload, .{});

    const cmf = zlib_stream[0];
    const flg = zlib_stream[1];
    // RFC 1950 assigns CM=8 to DEFLATE.
    try checkInt(w, "RFC 1950 CM", cmf & 0x0F, 8);
    // CINFO=7 represents a 32 KiB window; larger values are invalid.
    try checkInt(w, "RFC 1950 CINFO", cmf >> 4, 7);
    // RFC 1950 requires CMF*256+FLG to be divisible by 31.
    try checkInt(
        w,
        "RFC 1950 (CMF*256+FLG) mod 31",
        (@as(u32, cmf) * 256 + @as(u32, flg)) % 31,
        0,
    );
    // This stream uses no preset dictionary.
    try checkInt(w, "RFC 1950 FDICT clear", flg & 0x20, 0);
    // The RFC 1950 Adler-32 trailer is stored big-endian.
    var trailer: u32 = 0;
    for (zlib_stream[zlib_len - 4 .. zlib_len]) |byte| trailer = (trailer << 8) | byte;
    try checkInt(w, "RFC 1950 ADLER32 trailer", trailer, payload_adler32);

    // Compare one-shot and streaming decode routes.
    var back: [1024]u8 = undefined;
    try checkString(
        w,
        "uncompress round trip",
        back[0..try zlib.uncompress(&back, zlib_stream[0..zlib_len])],
        payload,
    );
    // `uncompress2` advances the source pointer past the member it consumes.
    var zlib_stream_rest: []const u8 = zlib_stream[0..zlib_len];
    try checkString(
        w,
        "compress then uncompress2",
        back[0..try zlib.uncompress2(&back, &zlib_stream_rest)],
        payload,
    );

    // Round-trip zlib, raw DEFLATE, and gzip; raw DEFLATE has no wrapper.
    // Inline iteration lets each format label be concatenated at comptime.
    inline for ([_]zlib.Format{ .zlib, .raw, .gzip }) |format| {
        var encoded: [1024]u8 = undefined;
        var deflater: zlib.Deflater = .empty;
        try deflater.init(.{}, format);
        const produced = (try deflater.runAll(payload, &encoded)).produced;
        // `deflateBound` is an upper bound, not the expected output length.
        try checkInt(
            w,
            @tagName(format) ++ ": deflateBound bounds the output",
            if (produced <= try deflater.bound(payload.len)) @as(u64, 1) else @as(u64, 0),
            1,
        );
        // Check the stream's own input and output totals.
        try checkInt(w, @tagName(format) ++ ": total_in", deflater.totalIn(), payload.len);
        try checkInt(w, @tagName(format) ++ ": total_out", deflater.totalOut(), produced);
        deflater.deinit();

        var inflater: zlib.Inflater = .empty;
        try inflater.init(format);
        var decoded: [1024]u8 = undefined;
        const step = try inflater.runAll(encoded[0..produced], &decoded);
        try checkString(w, @tagName(format) ++ ": round trip", decoded[0..step.produced], payload);
        // Reset reuses the stream without another initialization.
        try inflater.reset();
        try checkInt(w, @tagName(format) ++ ": total_in after reset", inflater.totalIn(), 0);
        inflater.deinit();
    }

    // A short destination returns `BufError` and may contain a stream prefix.
    // Use `compressBound` to size the retry buffer.
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

    // Exercise the gzip file API and inspect its header through `readHeader`.
    var path_buffer: [256]u8 = undefined;
    // Use the process ID for a temporary path; this process is its only writer.
    const path = try std.mem.printSentinel(&path_buffer, "zlib-smoke-{d}.gz", .{runTag()}, 0);
    // Each `Dir` operation receives the process I/O instance explicitly.
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var file = try zlib.Gzip.openWrite(path);
        defer file.deinit();
        try checkInt(w, "gzwrite took the whole payload", try file.write(payload), payload.len);
        // Set parameters before reading begins.
        try file.flush(.sync_flush);
    }

    {
        var file = try zlib.Gzip.openRead(path);
        defer file.deinit();

        var read_buffer: [1024]u8 = undefined;
        var filled: usize = 0;
        while (true) {
            // Pass the slice itself, not a pointer to the slice.
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

    // Register the buffer before decoding; zlib fills it during inflate.
    // Read the parsed fields after decoding completes.
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
        // RFC 1952 assigns OS=3 to Unix.
        try checkInt(w, "gzip OS byte is 3 (Unix)", header.os, 3);
        // Level 9 writes XFL=2 for maximum compression.
        try checkInt(w, "gzip XFL byte is 2 at level 9", header.xflags, 2);
        // A member written from memory has no timestamp.
        try checkInt(w, "gzip MTIME is 0 for a member this program wrote", header.time, 0);
        // `done` means zlib completed the header.
        try checkError(w, "gzip header reported done", header.done);
        // This member was written from memory, so it has no FNAME.
        try checkError(w, "no FNAME in a member this program wrote", header.nameSlice() == null);
    }

    // Check `zError` through the public entry point.
    try checkString(w, "zError(Z_DATA_ERROR)", zlib.zError(-3), "data error");
    try checkString(w, "zError(Z_STREAM_END)", zlib.zError(1), "stream end");

    // Call `get_crc_table` through the raw C declarations; the facade does not wrap it.
    const table = zlib.c.get_crc_table();
    try checkError(w, "get_crc_table returned a table", table != null);

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// Computes the `uInt` width code encoded in `zlibCompileFlags`.
fn uIntWidthCode() u32 {
    return switch (@sizeOf(zlib.c.uInt)) {
        2 => 0,
        4 => 1,
        8 => 2,
        else => 3,
    };
}

/// Returns a per-process temporary-file suffix across supported targets.
fn runTag() u64 {
    return switch (@import("builtin").target.os.tag) {
        .windows => @as(u64, std.os.windows.GetCurrentProcessId()),
        else => @intCast(std.c.getpid()),
    };
}

/// Prints an integer result and fails if it differs from `expected`.
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
