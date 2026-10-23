// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.

//! Exercises the published `zlib` module from a separate package, including translated headers and artifact.
//! Checks use RFC layouts, zlib 1.2.13 fixture checksums, and facade-versus-raw symbol agreement.
//! Supports linked and runtime-loaded builds; runtime mode requires an explicit provider.

const std = @import("std");
const zlib = @import("zlib");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// Resolves the provider from `--provider <path>` or `ZLIB_TEST_PROVIDER`.
/// Does not search default locations or fall back to a linked copy.
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

/// Reports missing runtime-provider configuration.
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

/// 275-byte payload shared with `fixtures/plain.bin`.
/// Includes a NUL at offset 251 and `0xff` to test length-based binary handling.
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

    // Runtime builds load the explicit provider before facade calls.
    if (comptime zlib.runtime_loaded) {
        try zlib.load(.{ .path = try providerRequest(init) });
    }

    try w.print("zlib consumer\n", .{});
    // Print the version returned by the selected provider.
    try w.print("{s} provider reports: {s}\n", .{
        if (zlib.runtime_loaded) "loaded" else "linked",
        zlib.zlibVersion(),
    });

    // Compare the header version with the provider's reported version.
    try checkString(w, "ZLIB_VERSION from the package's headers", zlib.version, "1.3.2");
    try checkString(w, "the provider agrees with those headers", zlib.zlibVersion(), "1.3.2");
    try checkInt(w, "ZLIB_VERNUM from src/zlib.h:45", zlib.version_num, 0x1320);

    // Check the provider's debug and WinAPI configuration flags.
    const flags = zlib.zlibCompileFlags();
    try checkInt(w, "compile flag bit 8 (ZLIB_DEBUG) clear", flags & zlib.flag_debug, 0);
    try checkInt(w, "compile flag bit 10 (ZLIB_WINAPI) clear", flags & zlib.flag_winapi, 0);

    // Check empty-input starts and payload checksums against zlib 1.2.13 records.
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

    // Compare `adler32_combine` with the whole-input result.
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

    // Check the one-shot round trip and the produced RFC 1950 wrapper.
    var encoded: [1024]u8 = undefined;
    const encoded_len = try zlib.compress2(&encoded, payload, .{});

    const cmf = encoded[0];
    const flg = encoded[1];
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

    var decoded: [1024]u8 = undefined;
    try checkString(
        w,
        "uncompress round trip",
        decoded[0..try zlib.uncompress(&decoded, encoded[0..encoded_len])],
        payload,
    );

    // Exercise streaming state in all formats to check layout and return codes.
    // Inline iteration keeps the format label available at comptime.
    inline for ([_]zlib.Format{ .zlib, .raw, .gzip }) |format| {
        var out: [1024]u8 = undefined;
        var deflater: zlib.Deflater = .empty;
        try deflater.init(.{ .level = .best_compression }, format);
        // Parenthesize the `try` result before reading its field.
        const produced = (try deflater.runAll(payload, &out)).produced;
        // `deflateBound` is this stream's upper bound.
        // Convert the runtime comparison before passing it to `checkInt`.
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

    // A short destination returns `BufError` after zlib writes available output.
    // Check its prefix rather than assuming the buffer remains unchanged.
    var short: [8]u8 = @splat(0xA5);
    try checkError(
        w,
        "a short destination reports BufError",
        zlib.compress2(&short, payload, .{}) == error.BufError,
    );
    // CMF identifies DEFLATE; a changed sentinel confirms output was written.
    try checkInt(w, "the short destination was written", short[0] & 0x0F, 8);
    try checkInt(
        w,
        "compressBound is at least the input length",
        @intFromBool(zlib.compressBound(payload.len) >= payload.len),
        1,
    );

    // Read the gzip file bytes directly so the check does not rely on zlib's parser.
    var path_buffer: [256]u8 = undefined;
    // Use the process I/O random source to create a temporary file name.
    var random_source = std.Random.IoSource{ .io = io };
    const path = try std.mem.printSentinel(&path_buffer, "zlib-consumer-{d}.gz", .{
        random_source.interface().int(u32),
    }, 0);
    // File operations receive the process I/O instance explicitly.
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(io, path) catch {};

    {
        var file = try zlib.Gzip.openWrite(path);
        defer file.deinit();
        try checkInt(w, "gzwrite took the whole payload", try file.write(payload), payload.len);
        // Flush the gzip member before closing the file.
        try file.flush(.sync_flush);
    }

    {
        const bytes = try cwd.readFileAlloc(io, path, init.arena.allocator(), .limited(4096));
        // RFC 1952 fixes ID1/ID2 at 0x1f/0x8b.
        try checkInt(w, "RFC 1952 ID1", bytes[0], 0x1f);
        try checkInt(w, "RFC 1952 ID2", bytes[1], 0x8b);
        // RFC 1952 assigns CM=8 to DEFLATE.
        try checkInt(w, "RFC 1952 CM", bytes[2], 8);
        // Reserved FLG bits must be zero (RFC 1952 §2.3.1).
        try checkInt(w, "RFC 1952 reserved FLG bits", bytes[3] & 0xF0, 0);
        // RFC 1952 stores CRC-32 and ISIZE little-endian in the trailer.
        var crc: u32 = 0;
        for (0..4) |i| crc |= @as(u32, bytes[bytes.len - 8 + i]) << @intCast(8 * i);
        // Avoid shadowing Zig's primitive `isize` type.
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
            // Pass the slice itself, not a pointer to the slice.
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

    // Compare facade routing with raw symbol access and the embedded header version.
    // This detects provider mismatches between the dispatch and translated declarations.
    try checkString(w, "route check: facade and raw escape hatch agree",
        try rawVersion(), zlib.zlibVersion());
    try checkString(w, "route check: the provider matches these headers",
        zlib.zlibVersion(), zlib.version);

    // Call a translated declaration that the typed facade does not wrap.
    var stream: zlib.c.z_stream = std.mem.zeroes(zlib.c.z_stream);
    try checkInt(w, "raw deflateInit2_ returned Z_OK", zlib.c.deflateInit2_(
        &stream,
        6,
        // `Z_DEFLATED` is translated as `c_int`.
        zlib.c.Z_DEFLATED,
        15,
        8,
        0,
        zlib.version,
        @sizeOf(zlib.c.z_stream),
    ), 0);
    defer _ = zlib.c.deflateEnd(&stream);
    // Exercise the raw `deflateTune` signature with five arguments.
    try checkInt(w, "raw deflateTune returned Z_OK", zlib.c.deflateTune(&stream, 5, 5, 5, 128), 0);

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// Returns the translated `zlibVersion` declaration through the C namespace.
/// Runtime builds route this call through the generated dispatch.
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
