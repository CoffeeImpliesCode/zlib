// SPDX-License-Identifier: zlib
// See FORK-LICENSE.md for what that identifier covers.

//! Tests compare independent GNU gzip and CPython zlib fixtures, RFC-derived
//! known answers, and recorded checksums; fixture data lives under `fixtures/`.
//! zlib uses libc allocation, so `std.testing.allocator` cannot track its allocations.

const std = @import("std");
const zlib = @import("zlib");
const testing = std.testing;

/// Creates a per-process fixture name without target-specific PID types.
fn runTag() u64 {
    return switch (@import("builtin").target.os.tag) {
        .windows => @as(u64, std.os.windows.GetCurrentProcessId()),
        else => @intCast(std.c.getpid()),
    };
}

/// Shared plaintext fixture; producer and checksum records live under `fixtures/`.
const plain = @embedFile("fixtures/plain.bin");

/// GNU gzip 1.13 output: `gzip -1 -n -c`.
const gzip_n1 = @embedFile("fixtures/gzip/gzip-n1.bin");

/// GNU gzip 1.13 output: `gzip -9 -n -c`.
const gzip_n9 = @embedFile("fixtures/gzip/gzip-n9.bin");

/// GNU gzip 1.13 output with FNAME: `gzip -9 -N -c`.
const gzip_n9_name = @embedFile("fixtures/gzip/gzip-n9-name.bin");

/// zlib 1.2.13 output from `zlib.compress(plain, 1)`.
const zlib_n1 = @embedFile("fixtures/pyzlib/zlib-n1.z");

/// zlib 1.2.13 output from `zlib.compress(plain, 6)`.
const zlib_n6 = @embedFile("fixtures/pyzlib/zlib-n6.z");

/// zlib 1.2.13 output from `zlib.compress(plain, 9)`.
const zlib_n9 = @embedFile("fixtures/pyzlib/zlib-n9.z");

/// zlib 1.2.13 raw DEFLATE output from `compressobj(6, DEFLATED, -15)`.
const raw_n6 = @embedFile("fixtures/pyzlib/raw-n6.bin");

/// zlib 1.2.13 raw DEFLATE output from `compressobj(9, DEFLATED, -15)`.
const raw_n9 = @embedFile("fixtures/pyzlib/raw-n9.bin");

/// Adler-32 of `plain`, recorded by zlib 1.2.13.
const recorded_adler32: u32 = 3970324232;

/// CRC-32 of `plain`, recorded by zlib 1.2.13.
const recorded_crc32: u32 = 1368583364;

/// Environment variable naming the shared object used by runtime-loading tests.
const provider_variable = "ZLIB_TEST_PROVIDER";

/// Ensures the native library is loaded before a test uses the facade.
/// Runtime-loading tests require `ZLIB_TEST_PROVIDER` when no provider is loaded.
fn nativeReady() void {
    if (comptime !zlib.runtime_loaded) return;
    if (zlib.loadedSource() != null) return;

    var buffer: [4096]u8 = undefined;
    const value = std.testing.environ.getAlloc(testing.allocator, provider_variable) catch
        missingProvider();
    defer testing.allocator.free(value);
    if (value.len == 0 or value.len > buffer.len) missingProvider();
    @memcpy(buffer[0..value.len], value);
    zlib.load(.{ .path = buffer[0..value.len] }) catch |err| {
        std.debug.print(
            "tests.zig: loading " ++ provider_variable ++ " = \"{s}\" failed: {t}\n",
            .{ buffer[0..value.len], err },
        );
        @panic("tests.zig: the provider named by " ++ provider_variable ++
            " did not load; nothing below this line ran");
    };
}

fn missingProvider() noreturn {
    @panic(
        "tests.zig: this is a runtime-loading build and " ++ provider_variable ++
            " is not set. Point it at a shared object exporting the declarations " ++
            "of zig/translate.h, for example the one `zig build -Dlinkage=dynamic` " ++
            "installs, and export it for the whole `zig build` invocation: the " ++
            "build cannot inject a path into a run step's environment.",
    );
}

// Specification-derived checksum references, independent of the facade.

/// Adler-32 recurrence from RFC 1950 §8.2.
fn referenceAdler32(bytes: []const u8) u32 {
    const modulus: u32 = 65521;
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (bytes) |byte| {
        s1 = (s1 + byte) % modulus;
        s2 = (s2 + s1) % modulus;
    }
    return s2 * 65536 + s1;
}

/// Computes reflected CRC-32/ISO-HDLC with polynomial `0xEDB88320`.
fn referenceCrc32(bytes: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return ~crc;
}

/// Encodes the translated header's `uInt` width as `zlibCompileFlags` does.
fn uIntWidthCode() u32 {
    return switch (@sizeOf(zlib.c.uInt)) {
        2 => 0,
        4 => 1,
        8 => 2,
        else => 3,
    };
}

// RFC 1951 §3.1.1 packs data bits LSB-first and Huffman codes MSB-first.

/// Bit writer with LSB-first data and MSB-first Huffman-code paths.
const BitWriter = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    bit_buffer: u32 = 0,
    bit_count: u8 = 0,

    /// Appends `count` bits of `value`, least-significant bit first.
    fn writeLsb(self: *BitWriter, count: u8, value: u32) void {
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            const bit: u32 = (value >> @intCast(i)) & 1;
            self.bit_buffer |= bit << @intCast(self.bit_count);
            self.bit_count += 1;
            if (self.bit_count == 8) {
                self.bytes[self.len] = @truncate(self.bit_buffer);
                self.len += 1;
                self.bit_buffer = 0;
                self.bit_count = 0;
            }
        }
    }

    /// Appends `count` bits of `code`, most-significant bit first.
    fn writeMsb(self: *BitWriter, count: u8, code: u32) void {
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            const shift: u8 = count - 1 - i;
            const bit: u32 = (code >> @intCast(shift)) & 1;
            self.bit_buffer |= bit << @intCast(self.bit_count);
            self.bit_count += 1;
            if (self.bit_count == 8) {
                self.bytes[self.len] = @truncate(self.bit_buffer);
                self.len += 1;
                self.bit_buffer = 0;
                self.bit_count = 0;
            }
        }
    }

    /// Flushes the partial byte with zero padding and returns the written bytes.
    fn finish(self: *BitWriter) []const u8 {
        if (self.bit_count > 0) {
            self.bytes[self.len] = @truncate(self.bit_buffer);
            self.len += 1;
            self.bit_buffer = 0;
            self.bit_count = 0;
        }
        return self.bytes[0..self.len];
    }
};

/// Returns the fixed literal/length code assigned by RFC 1951 §3.2.6.
fn fixedHuffmanCode(symbol: u16) struct { count: u8, code: u32 } {
    return switch (symbol) {
        0...143 => .{ .count = 8, .code = 0x30 + symbol },
        144...255 => .{ .count = 9, .code = 0x190 + (symbol - 144) },
        256...279 => .{ .count = 7, .code = symbol - 256 },
        280...287 => .{ .count = 8, .code = 0xC0 + (symbol - 280) },
        else => unreachable,
    };
}

/// Checks the ten fixed gzip header bytes defined by RFC 1952 §2.3.1.
fn expectGzipHeader(
    bytes: []const u8,
    expected_xfl: u8,
    expected_ftxt: bool,
    expected_fname: bool,
) !void {
    // RFC 1952 fixes ID1/ID2 at 0x1f/0x8b.
    try testing.expectEqual(@as(u8, 0x1f), bytes[0]);
    try testing.expectEqual(@as(u8, 0x8b), bytes[1]);
    // RFC 1952 assigns CM=8 to DEFLATE and reserves values 0–7.
    try testing.expectEqual(@as(u8, 8), bytes[2]);

    // RFC 1952 §2.3.1 defines the flag-bit positions.
    const flg = bytes[3];
    try testing.expectEqual(expected_fname, (flg & 0x08) != 0);
    try testing.expectEqual(expected_ftxt, (flg & 0x01) != 0);
    // Reserved FLG bits must be zero (RFC 1952 §2.3.1).
    try testing.expectEqual(@as(u8, 0), flg & 0xF0);
    try testing.expectEqual(@as(u8, 0), flg & 0x02); // FHCRC
    try testing.expectEqual(@as(u8, 0), flg & 0x04); // FEXTRA
    try testing.expectEqual(@as(u8, 0), flg & 0x10); // FCOMMENT

    // MTIME is little-endian; zero means no timestamp (RFC 1952 §2.3.1).
    var mtime: u32 = 0;
    for (0..4) |i| mtime |= @as(u32, bytes[4 + i]) << @intCast(8 * i);
    try testing.expectEqual(@as(u32, 0), mtime);

    // XFL=2 marks maximum compression; XFL=4 marks fastest compression.
    try testing.expectEqual(expected_xfl, bytes[8]);

    // OS=3 denotes Unix; see `fixtures/PROVENANCE.md`.
    try testing.expectEqual(@as(u8, 3), bytes[9]);
}

/// Checks a gzip member's CRC-32 and ISIZE trailer (RFC 1952 §2.3).
fn expectGzipTrailer(bytes: []const u8) !void {
    const trailer = bytes[bytes.len - 8 ..];
    var crc: u32 = 0;
    for (0..4) |i| crc |= @as(u32, trailer[i]) << @intCast(8 * i);
    var isize_code: u32 = 0;
    for (0..4) |i| isize_code |= @as(u32, trailer[4 + i]) << @intCast(8 * i);

    try testing.expectEqual(referenceCrc32(plain), crc);
    // CRC-32 covers the uncompressed data; ISIZE is its length modulo 2^32.
    try testing.expectEqual(@as(u32, @intCast(plain.len)), isize_code);
}

/// Inflates a gzip member and returns the produced plaintext length.
fn inflateGzip(bytes: []const u8, output: []u8) !usize {
    var inflater: zlib.Inflater = .empty;
    try inflater.init(.gzip);
    defer inflater.deinit();
    const step = try inflater.runAll(bytes, output);
    // Z_STREAM_END marks normal completion.
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    return step.produced;
}

test "runtime provider round-trip validation completes before publication" {
    if (comptime !zlib.runtime_loaded) return;
    nativeReady();
    try testing.expect(zlib.loadedSource() != null);
}

// Decode GNU gzip fixtures and check their headers and trailers against RFC 1952.
test "GNU gzip 1.13 members decode to the recorded plaintext, header fields per RFC 1952" {
    nativeReady();

    var output: [512]u8 = undefined;

    // `gzip -1 -n` uses XFL=4 for fastest compression (RFC 1952 §2.3.1).
    try expectGzipHeader(gzip_n1, 4, false, false);
    try expectGzipTrailer(gzip_n1);
    try testing.expectEqual(plain.len, try inflateGzip(gzip_n1, &output));
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);

    // `gzip -9 -n` uses XFL=2 for maximum compression (RFC 1952 §2.3.1).
    try expectGzipHeader(gzip_n9, 2, false, false);
    try expectGzipTrailer(gzip_n9);
    try testing.expectEqual(plain.len, try inflateGzip(gzip_n9, &output));
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);

    try testing.expectEqual(gzip_n1[10 .. gzip_n1.len - 8].len, gzip_n9[10 .. gzip_n9.len - 8].len);
}

// The `-N` fixture carries FNAME; the two `-n` fixtures do not.
test "gzip -N carries FNAME and the name RFC 1952 describes" {
    nativeReady();

    const flg = gzip_n9_name[3];
    // src/doc/rfc1952.txt:306: bit 3 is FNAME.
    try testing.expectEqual(@as(u8, 0x08), flg & 0x08);

    // RFC 1952 places a NUL-terminated FNAME after the fixed header.
    const after_header = gzip_n9_name[10..];
    const end = std.mem.indexOfScalar(u8, after_header, 0) orelse
        return error.FnameNotTerminated;
    try testing.expectEqualStrings("plain.bin", after_header[0..end]);

    // The `-N` fixture carries a timestamp; the two `-n` fixtures do not.
    var mtime: u32 = 0;
    for (0..4) |i| mtime |= @as(u32, gzip_n9_name[4 + i]) << @intCast(8 * i);
    try testing.expect(mtime != 0);

    var output: [512]u8 = undefined;
    try testing.expectEqual(plain.len, try inflateGzip(gzip_n9_name, &output));
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);
}

// Check the same FNAME through zlib's `inflateGetHeader` interface.
test "inflateGetHeader reads gzip-n9-name.bin's FNAME" {
    nativeReady();

    var buffers: zlib.HeaderBuffer = .{};
    var inflater: zlib.Inflater = .empty;
    try inflater.init(.gzip);
    defer inflater.deinit();

    // Register the header buffer before inflate; zlib fills it while decoding.
    try inflater.readHeader(&buffers);

    var output: [512]u8 = undefined;
    const step = try inflater.runAll(gzip_n9_name, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    try testing.expectEqual(plain.len, step.produced);
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);

    const header = buffers.current();
    // The parsed name must match the FNAME bytes checked above.
    try testing.expectEqualStrings("plain.bin", header.nameSlice().?);

    // OS=3 and XFL=2 match the byte-level assertions.
    try testing.expectEqual(@as(i32, 3), header.os);
    try testing.expectEqual(@as(i32, 2), header.xflags);

    // The `-N` fixture preserves its timestamp.
    try testing.expect(header.time != 0);

    // `done` marks completion; this member has no FCOMMENT or FEXTRA.
    try testing.expect(header.done);
    try testing.expect(header.commentSlice() == null);
    try testing.expect(header.extraSlice() == null);
}

// Exercise this member through the `gz*` file layer as well as the stream API.
test "the gz file stream decodes the same gzip member to the same plaintext" {
    nativeReady();

    // Exercise `Gzip`'s file-layer read path.
    var path_buffer: [256]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "zlib-test-{d}.gz", .{runTag()}, 0);
    // Tests use the process-wide single-threaded I/O instance.
    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // Write the foreign gzip bytes unchanged to exercise file-layer decoding.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = gzip_n1 });

    {
        var file = try zlib.Gzip.openRead(path);
        defer file.deinit();

        var output: [512]u8 = undefined;
        var filled: usize = 0;
        while (true) {
            // Pass the mutable slice itself to `readSome`.
            const room: []u8 = output[filled..];
            const got = file.readSome(room) catch |err| switch (err) {
                error.EndOfInput => break,
                else => return err,
            };
            if (got == 0) break;
            filled += got;
        }
        try testing.expectEqual(plain.len, filled);
        try testing.expectEqualSlices(u8, plain, output[0..filled]);
        try testing.expect(file.eof());
    }

    // Also exercise file-layer writes, then read their gzip member back.
    {
        var out = try zlib.Gzip.openWrite(path);
        defer out.deinit();
        try testing.expectEqual(plain.len, try out.write(plain));
    }

    var written = try zlib.Gzip.openRead(path);
    defer written.deinit();
    var again: [512]u8 = undefined;
    var read_back: usize = 0;
    while (true) {
        // A short `read` is not EOF; continue until `EndOfInput`.
        const room: []u8 = again[read_back..];
        const got = written.read(room) catch |err| switch (err) {
            error.EndOfInput => break,
            else => return err,
        };
        if (got == 0) break;
        read_back += got;
    }
    try testing.expectEqual(plain.len, read_back);
    try testing.expectEqualSlices(u8, plain, again[0..read_back]);
}

// A zlib-format stream has no gzip header for `inflateGetHeader` to read.
test "readHeader refuses a stream that has no gzip header" {
    nativeReady();

    var buffers: zlib.HeaderBuffer = .{};
    var inflater: zlib.Inflater = .empty;
    try inflater.init(.zlib);
    defer inflater.deinit();
    try testing.expectError(error.StreamError, inflater.readHeader(&buffers));
}

/// Checks the zlib wrapper fields defined by RFC 1950 §2.2.
fn expectZlibWrapper(bytes: []const u8, expected_flevel: u8) !void {
    // RFC 1950 splits CMF into the CM and CINFO fields.
    const cmf = bytes[0];
    // RFC 1950 assigns CM=8 to DEFLATE.
    try testing.expectEqual(@as(u8, 8), cmf & 0x0F);
    // CINFO=7 indicates a 32 KiB window; larger values are invalid.
    try testing.expectEqual(@as(u8, 7), cmf >> 4);

    const flg = bytes[1];
    // FLG contains FCHECK, FDICT, and FLEVEL; these fixtures use no dictionary.
    try testing.expectEqual(@as(u8, 0), flg & 0x20);
    try testing.expectEqual(expected_flevel, flg >> 6);
    // RFC 1950 requires CMF*256+FLG to be divisible by 31.
    const combined: u32 = @as(u32, cmf) * 256 + @as(u32, flg);
    try testing.expectEqual(@as(u32, 0), combined % 31);

    // The trailer is the uncompressed data's Adler-32, stored big-endian.
    var adler: u32 = 0;
    const tail = bytes[bytes.len - 4 ..];
    for (tail) |byte| adler = (adler << 8) | byte;
    try testing.expectEqual(referenceAdler32(plain), adler);
}

// Decode CPython zlib 1.2.13 output after checking its RFC 1950 framing.
test "zlib 1.2.13 wrappers decode to the recorded plaintext, layout per RFC 1950" {
    nativeReady();

    var output: [512]u8 = undefined;

    // FLEVEL=0, 2, and 3 denote fastest, default, and maximum compression.
    try expectZlibWrapper(zlib_n1, 0);
    try expectZlibWrapper(zlib_n6, 2);
    try expectZlibWrapper(zlib_n9, 3);

    for ([_][]const u8{ zlib_n1, zlib_n6, zlib_n9 }) |bytes| {
        var rest: []const u8 = bytes;
        const step = try zlib.uncompress2(&output, &rest);
        try testing.expectEqual(plain.len, step);
        try testing.expectEqualSlices(u8, plain, output[0..step]);
    }
}

// These zlib 1.2.13 fixtures are raw DEFLATE streams (`windowBits = -15`).
test "zlib 1.2.13 raw deflate streams decode to the recorded plaintext" {
    nativeReady();

    var output: [512]u8 = undefined;
    for ([_][]const u8{ raw_n6, raw_n9 }) |bytes| {
        var inflater: zlib.Inflater = .empty;
        try inflater.init(.raw);
        defer inflater.deinit();
        const step = try inflater.runAll(bytes, &output);
        try testing.expectEqual(zlib.Status.stream_end, step.status);
        try testing.expectEqual(plain.len, step.produced);
        try testing.expectEqualSlices(u8, plain, output[0..step.produced]);
    }

    // Raw DEFLATE omits the two-byte zlib header and four-byte Adler-32 trailer.
    try testing.expectEqual(zlib_n9.len - 6, raw_n9.len);
    try testing.expectEqualSlices(u8, zlib_n9[2..][0..raw_n9.len], raw_n9);
}

// Upstream's `16 + MAX_WBITS` route selects gzip decoding (`src/Makefile.in:291`).
test "inflateInit2 at 16 + MAX_WBITS reads a gzip stream, as src/Makefile.in:291 says" {
    nativeReady();

    // `+16` selects gzip decoding; exercise it through `inflateInit2_`.
    var stream: zlib.c.z_stream = std.mem.zeroes(zlib.c.z_stream);
    const code = zlib.c.inflateInit2_(
        &stream,
        16 + 15,
        zlib.version,
        @sizeOf(zlib.c.z_stream),
    );
    try testing.expectEqual(@as(c_int, 0), code);
    // Check `inflateEnd` on the main path; defer also cleans up on early exits.
    defer _ = zlib.c.inflateEnd(&stream);

    // z_stream takes a mutable input pointer, so copy the embedded fixture.
    var input_buffer: [gzip_n9.len]u8 = undefined;
    @memcpy(&input_buffer, gzip_n9);
    stream.next_in = &input_buffer;
    stream.avail_in = @intCast(gzip_n9.len);
    var output: [512]u8 = undefined;
    stream.next_out = &output;
    stream.avail_out = @intCast(output.len);
    const got = zlib.c.inflate(&stream, @backingInt(zlib.Flush.finish));
    // src/zlib.h:182: Z_STREAM_END is how a complete member ends.
    try testing.expectEqual(@as(c_int, 1), got);
    try testing.expectEqual(plain.len, stream.total_out);
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);
    try testing.expectEqual(@as(c_int, 0), zlib.c.inflateEnd(&stream));
}

// Compare checksum results with the RFC recurrence and zlib 1.2.13 records.
test "the checksums agree with the RFC 1950 recurrence and with zlib 1.2.13" {
    nativeReady();

    // RFC 1950 initializes Adler-32 with s1=1.
    try testing.expectEqual(@as(u32, 1), zlib.checksum.adler32Empty());
    try testing.expectEqual(@as(u32, 1), referenceAdler32(""));

    // CRC-32 of empty input is zero.
    try testing.expectEqual(@as(u32, 0), zlib.checksum.crc32Empty());
    try testing.expectEqual(@as(u32, 0), referenceCrc32(""));

    // Both over the fixture, against the value zlib 1.2.13 recorded.
    try testing.expectEqual(referenceAdler32(plain), zlib.adler32(zlib.checksum.adler32_init, plain));
    try testing.expectEqual(recorded_adler32, zlib.adler32(zlib.checksum.adler32_init, plain));
    try testing.expectEqual(referenceCrc32(plain), zlib.crc32(zlib.checksum.crc32_init, plain));
    try testing.expectEqual(recorded_crc32, zlib.crc32(zlib.checksum.crc32_init, plain));

    // ISO-HDLC's check value for `123456789`; RFC 1952 gives no numeric value.
    try testing.expectEqual(@as(u32, 0xCBF43926), referenceCrc32("123456789"));
    try testing.expectEqual(@as(u32, 0xCBF43926), zlib.crc32(zlib.checksum.crc32_init, "123456789"));
}

// Build the fixed-Huffman block from RFC 1951 §3.2.6 and decode it.
// The code bits are assembled from the RFC assignment, not zlib's encoder.
test "a block built from RFC 1951 section 3.2.6 decodes to the literals it encodes" {
    nativeReady();

    const message = "zlib fixed Huffman known answer";
    var writer: BitWriter = .{};

    // BTYPE=01 selects fixed Huffman codes (RFC 1951 §3.2.6).
    writer.writeLsb(1, 1); // BFINAL = 1, the last block
    writer.writeLsb(2, 0b01); // BTYPE = 01, fixed Huffman

    for (message) |byte| {
        const entry = fixedHuffmanCode(byte);
        writer.writeMsb(entry.count, entry.code);
    }
    // Symbol 256 is the 7-bit end-of-block code (RFC 1951 §3.2.6).
    const end = fixedHuffmanCode(256);
    try testing.expectEqual(@as(u8, 7), end.count);
    try testing.expectEqual(@as(u32, 0), end.code);
    writer.writeMsb(end.count, end.code);

    const block = writer.finish();

    var inflater: zlib.Inflater = .empty;
    try inflater.init(.raw);
    defer inflater.deinit();
    var output: [256]u8 = undefined;
    const step = try inflater.runAll(block, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    try testing.expectEqualStrings(message, output[0..step.produced]);
}

// Construct and decode an RFC 1951 stored block.
test "a stored block from RFC 1951 section 3.2.4 round-trips its bytes" {
    nativeReady();

    const payload = "stored blocks are stored";
    var writer: BitWriter = .{};

    writer.writeLsb(1, 1); // BFINAL
    writer.writeLsb(2, 0b00); // BTYPE = 00, stored
    // Stored blocks align before their length fields (RFC 1951 §3.2.4).
    writer.writeLsb(@intCast((8 - (writer.bit_count % 8)) % 8), 0);
    try testing.expectEqual(@as(u8, 0), writer.bit_count);

    // LEN and NLEN are little-endian 16-bit fields; NLEN complements LEN.
    const len: u16 = @intCast(payload.len);
    writer.writeLsb(16, len);
    writer.writeLsb(16, ~len);
    for (payload) |byte| writer.writeLsb(8, byte);
    const block = writer.finish();

    var inflater: zlib.Inflater = .empty;
    try inflater.init(.raw);
    defer inflater.deinit();
    var output: [256]u8 = undefined;
    const step = try inflater.runAll(block, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    try testing.expectEqualStrings(payload, output[0..step.produced]);
}

// `compressBound` must cover output from every level, strategy, and window size.
test "compressBound is an upper bound for every level and strategy" {
    nativeReady();

    var output: [4096]u8 = undefined;
    const levels = [_]zlib.Level{
        .no_compression,              .best_speed,                  .best_compression,            .default_compression,
        @fromBackingInt(@intCast(2)), @fromBackingInt(@intCast(6)), @fromBackingInt(@intCast(8)),
    };
    const strategies = [_]zlib.Strategy{ .default, .filtered, .huffman_only, .rle, .fixed };

    for (levels) |level| {
        for (strategies) |strategy| {
            // The bound applies even to a stream with no compression.
            const bound = zlib.compressBound(plain.len);
            const produced = try zlib.compress2(&output, plain, .{
                .level = level,
                .strategy = strategy,
            });
            try testing.expect(produced <= bound);
            try testing.expect(bound >= plain.len);
        }
    }

    // Zero- and one-byte inputs also have documented bounds.
    try testing.expect(zlib.compressBound(0) > 0);
    try testing.expect(zlib.compressBound(1) > 1);
}

// `deflateBound` bounds output for one initialized stream.
test "deflateBound bounds what this deflate stream produces" {
    nativeReady();

    var output: [4096]u8 = undefined;
    for ([_]zlib.Level{ .best_speed, .no_compression, .best_compression }) |level| {
        var deflater: zlib.Deflater = .empty;
        try deflater.init(.{ .level = level }, .zlib);
        defer deflater.deinit();

        const bound = try deflater.bound(plain.len);
        const step = try deflater.runAll(plain, &output);
        const produced = step.produced;
        try testing.expect(produced <= bound);
        try testing.expect(bound >= plain.len);
    }
}

// A short destination reports insufficient space after writing a stream prefix.
// `compressBound` gives the required capacity; zlib may write before the error.
test "a short destination is refused and holds the leading part of the real stream" {
    nativeReady();

    // Sentinel bytes reveal which output positions zlib changed.
    const sentinel: u8 = 0xA5;
    var output: [8]u8 = @splat(sentinel);

    try testing.expectError(error.BufError, zlib.compress2(&output, plain, .{}));

    // Retry with the capacity reported by `compressBound`.
    const bound = zlib.compressBound(plain.len);
    var big: [512]u8 = undefined;
    const produced = try zlib.compress2(big[0..bound], plain, .{});
    try testing.expect(produced > output.len);

    // The short buffer contains a prefix of the successful stream.
    try testing.expectEqualSlices(u8, big[0..output.len], &output);
}

// A truncated raw stream returns `BufError` without reaching stream end.
// Check that output is a plaintext prefix and the remaining destination is untouched.
test "a truncated stream reports BufError and leaves the destination untouched" {
    nativeReady();

    // Use a real zlib 1.2.13 stream truncated within its DEFLATE data.
    const truncated = raw_n9[0 .. raw_n9.len / 2];

    const sentinel: u8 = 0x5A;
    var output: [512]u8 = @splat(sentinel);

    var inflater: zlib.Inflater = .empty;
    try inflater.init(.raw);
    defer inflater.deinit();

    // Drive the decoder step by step and check it never reaches stream end.
    var produced: usize = 0;
    var rest: []const u8 = truncated;
    var reached_end = false;
    while (true) {
        const step = inflater.run(rest, output[produced..], .no_flush) catch |err| {
            // No input or output progress produces `BufError`.
            try testing.expectEqual(error.BufError, err);
            break;
        };
        if (step.status == .stream_end) {
            reached_end = true;
            produced += step.produced;
            break;
        }
        if (step.consumed == 0 and step.produced == 0) {
            // With no input left, no progress means the stream is incomplete.
            try testing.expectError(
                error.BufError,
                inflater.run("", output[produced..], .no_flush),
            );
            break;
        }
        produced += step.produced;
        rest = rest[step.consumed..];
        if (rest.len == 0) {
            // The next call with no input must report the truncation.
            try testing.expectError(
                error.BufError,
                inflater.run("", output[produced..], .no_flush),
            );
            break;
        }
    }
    try testing.expect(!reached_end);

    // Produced bytes must be a plaintext prefix; the rest retains its sentinel.
    try testing.expect(produced <= plain.len);
    try testing.expectEqualSlices(u8, plain[0..produced], output[0..produced]);
    const tail = output[produced..];
    for (tail) |byte| try testing.expectEqual(sentinel, byte);
}

// Feed raw DEFLATE to a zlib-wrapper decoder, then verify recovery after reset.
// This structural header mismatch deterministically produces `DataError`.
test "a corrupt stream reports DataError and stays usable after inflateReset" {
    nativeReady();

    var output: [512]u8 = undefined;

    var inflater: zlib.Inflater = .empty;
    try inflater.init(.zlib);
    defer inflater.deinit();

    // `raw_n9` has no zlib header, so its first byte is not a valid CMF.
    try testing.expectError(error.DataError, inflater.runAll(raw_n9, &output));

    // Reset after the header error, then feed a valid RFC 1950 member.
    try inflater.reset();
    const step = try inflater.runAll(zlib_n9, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    try testing.expectEqual(plain.len, step.produced);
    try testing.expectEqualSlices(u8, plain, output[0..step.produced]);
}

// The one-shot `uncompress` route must reject a stream with an invalid header.
test "uncompressing a stream with no zlib header reports DataError" {
    nativeReady();

    var output: [512]u8 = undefined;
    try testing.expectError(error.DataError, zlib.uncompress(&output, raw_n9));
}

// Combined checksums must match hashing the concatenated input.
test "adler32_combine agrees with hashing the concatenation" {
    nativeReady();

    const split = 137; // deliberately not a round number and not a power of two
    const first = plain[0..split];
    const second = plain[split..];

    const whole = zlib.adler32(zlib.checksum.adler32_init, plain);
    const a = zlib.adler32(zlib.checksum.adler32_init, first);
    const b = zlib.adler32(zlib.checksum.adler32_init, second);
    try testing.expectEqual(whole, zlib.adler32_combine(a, b, second.len));

    // Check both degenerate cases: an empty first or second input.
    const only_first = zlib.adler32(zlib.checksum.adler32_init, first);
    try testing.expectEqual(only_first, zlib.adler32_combine(a, zlib.checksum.adler32_init, 0));

    const only_second = zlib.adler32(zlib.checksum.adler32_init, second);
    try testing.expectEqual(only_second, zlib.adler32_combine(zlib.checksum.adler32_init, b, second.len));

    // Check the same property for CRC-32.
    const c = zlib.crc32(zlib.checksum.crc32_init, first);
    const d = zlib.crc32(zlib.checksum.crc32_init, second);
    try testing.expectEqual(
        zlib.crc32(zlib.checksum.crc32_init, plain),
        zlib.crc32_combine(c, d, second.len),
    );
}

// The generated operator and `crc32_combine_op` must match `crc32_combine`.
test "crc32_combine_op agrees with crc32_combine" {
    nativeReady();

    const split = 91;
    const first = plain[0..split];
    const second = plain[split..];

    const c = zlib.crc32(zlib.checksum.crc32_init, first);
    const d = zlib.crc32(zlib.checksum.crc32_init, second);

    try testing.expectEqual(
        zlib.crc32_combine(c, d, second.len),
        zlib.crc32_combine_op(c, d, zlib.crc32_combine_gen(second.len)),
    );

    // A zero length generates the operator for x^0.
    try testing.expectEqual(@as(u32, 1) << 31, zlib.crc32_combine_gen(0));

    // Applying the zero operator returns zero.
    try testing.expectEqual(@as(u32, 0), zlib.crc32_combine_op(c, d, 0));
}

// Changing parameters mid-stream must preserve plaintext and affect output.
test "deflateParams changes the ratio mid-stream and keeps the plaintext intact" {
    nativeReady();

    // Split after input is consumed so old settings finish the pending data.
    const split = 137;
    const first = plain[0..split];
    const second = plain[split..];

    var fast: [1024]u8 = undefined;
    var slow: [1024]u8 = undefined;

    // A stream that keeps its initial compression level.
    var steady: zlib.Deflater = .empty;
    try steady.init(.{ .level = .best_speed }, .zlib);
    const steady_len = (try steady.runAll(plain, &fast)).produced;
    // Check input totals before `deinit` clears the stream.
    try testing.expectEqual(@as(usize, plain.len), steady.totalIn());
    steady.deinit();

    // A stream that switches to level 9 after the first half.
    var switched: zlib.Deflater = .empty;
    try switched.init(.{ .level = .best_speed }, .zlib);
    _ = try switched.run(first, slow[0..], .no_flush);
    try switched.params(.best_compression, .default);
    // `deflateParams` may emit pending output using the old parameters.
    // Use `totalOut` for the next output offset because params writes bytes itself.
    _ = try switched.runAll(second, slow[switched.totalOut()..]);
    try testing.expectEqual(@as(usize, plain.len), switched.totalIn());
    const switched_len = switched.totalOut();
    switched.deinit();

    // Both streams must still decode to the same plaintext.
    var check: [512]u8 = undefined;
    try testing.expectEqualSlices(u8, plain, check[0..try zlib.uncompress(&check, fast[0..steady_len])]);
    try testing.expectEqualSlices(u8, plain, check[0..try zlib.uncompress(&check, slow[0..switched_len])]);

    // Different output lengths show that the parameter change took effect.
    try testing.expect(steady_len != switched_len);
}

// Continuing a checksum must match hashing the concatenated input.
test "the running checksum equals hashing the whole input" {
    nativeReady();

    const split = 61;
    const a = zlib.adler32(zlib.checksum.adler32_init, plain[0..split]);
    const b = zlib.adler32(a, plain[split..]);
    try testing.expectEqual(zlib.adler32(zlib.checksum.adler32_init, plain), b);

    const c = zlib.crc32(zlib.checksum.crc32_init, plain[0..split]);
    const d = zlib.crc32(c, plain[split..]);
    try testing.expectEqual(zlib.crc32(zlib.checksum.crc32_init, plain), d);
}

// Ending one stream twice must not disturb another stream.
test "deinit is idempotent and one stream's end does not disturb another" {
    nativeReady();

    var output: [512]u8 = undefined;

    var a: zlib.Deflater = .empty;
    try a.init(.{}, .zlib);
    var b: zlib.Deflater = .empty;
    try b.init(.{ .level = .best_speed }, .zlib);

    const first_a = try a.runAll(plain, &output);
    const first_b = try b.runAll(plain, &output);
    // `produced` counts compressed output, not input bytes.
    try testing.expect(first_a.produced < plain.len);
    try testing.expect(first_b.produced < plain.len);

    a.deinit();
    // A second `deinit` must not end the already-freed stream again.
    a.deinit();

    // Ending `a` must leave `b`'s totals and container unchanged.
    try testing.expectEqual(@as(usize, plain.len), b.totalIn());
    try testing.expectEqual(zlib.Format.zlib, b.container());

    // Reset `b` after `Z_STREAM_END` before using it again.
    try b.reset();
    const step = try b.runAll(plain, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    // The reset preserves `b`'s compression configuration.
    try testing.expectEqual(first_b.produced, step.produced);
    try testing.expectEqualSlices(u8, output[0..first_b.produced], output[0..step.produced]);
    b.deinit();
}

// `reset` returns a used deflate stream to an initialized state.
test "deflateReset reuses a stream's configuration" {
    nativeReady();

    var output: [512]u8 = undefined;

    var deflater: zlib.Deflater = .empty;
    try deflater.init(.{ .level = .best_compression }, .zlib);
    defer deflater.deinit();

    const first = try deflater.runAll(plain, &output);
    try testing.expectEqual(plain.len, first.consumed);

    try deflater.reset();
    // Reset clears input and output totals.
    try testing.expectEqual(@as(usize, 0), deflater.totalIn());
    try testing.expectEqual(@as(usize, 0), deflater.totalOut());

    const second = try deflater.runAll(plain, &output);
    try testing.expectEqual(first.produced, second.produced);
}

// `uncompress2` advances its input pointer past the member it reads.
test "uncompress2 consumes exactly one member and leaves the rest" {
    nativeReady();

    // Join two real members and verify both can be decoded separately.
    var both: [512]u8 = undefined;
    @memcpy(both[0..zlib_n9.len], zlib_n9);
    @memcpy(both[zlib_n9.len..][0..zlib_n6.len], zlib_n6);
    const joined = both[0 .. zlib_n9.len + zlib_n6.len];

    var rest: []const u8 = joined;
    var output: [512]u8 = undefined;

    const first_len = try zlib.uncompress2(&output, &rest);
    try testing.expectEqual(plain.len, first_len);
    try testing.expectEqualSlices(u8, plain, output[0..first_len]);
    // Only the first member is consumed.
    try testing.expectEqual(zlib_n9.len, joined.len - rest.len);
    try testing.expectEqual(zlib_n6.len, rest.len);

    const second_len = try zlib.uncompress2(&output, &rest);
    try testing.expectEqual(plain.len, second_len);
    try testing.expectEqualSlices(u8, plain, output[0..second_len]);
    try testing.expectEqual(@as(usize, 0), rest.len);
}

// Round trips supplement, but do not replace, interoperability tests.
test "round trips through every format come back byte for byte" {
    nativeReady();

    var output: [1024]u8 = undefined;

    for ([_]zlib.Format{ .zlib, .raw, .gzip }) |format| {
        var deflater: zlib.Deflater = .empty;
        try deflater.init(.{}, format);
        const deflated = try deflater.runAll(plain, &output);
        const produced = deflated.produced;
        deflater.deinit();

        var inflater: zlib.Inflater = .empty;
        try inflater.init(format);
        defer inflater.deinit();
        var back: [1024]u8 = undefined;
        const step = try inflater.runAll(output[0..produced], &back);
        try testing.expectEqual(zlib.Status.stream_end, step.status);
        try testing.expectEqualSlices(u8, plain, back[0..step.produced]);
    }

    // The fixture contains binary bytes, including NUL; round-trip assertions cover them.
    try testing.expect(std.mem.indexOfScalar(u8, plain, 0) != null);
}

// Read provider version and flags through the facade's C escape hatch.
test "the provider reports this SDK's version and none of the refused configurations" {
    nativeReady();

    try testing.expectEqualStrings(zlib.version, zlib.zlibVersion());

    const flags = zlib.zlibCompileFlags();
    // Check the debug and WinAPI flags refused by the runtime loader.
    try testing.expectEqual(@as(u32, 0), flags & zlib.flag_debug);
    try testing.expectEqual(@as(u32, 0), flags & zlib.flag_winapi);

    // `zlibCompileFlags` stores the translated header's `uInt` width in bits 0–1.
    // Derive the expected code from that header, not a host-specific constant.
    try testing.expectEqual(uIntWidthCode(), (flags >> 0) & 0x3);
}

// Check every status string from zlib's `zError` table.
test "zError spells every status code the header defines" {
    nativeReady();

    // The expected strings come from `src/zutil.c`.
    try testing.expectEqualStrings("", zlib.zError(0));
    try testing.expectEqualStrings("stream end", zlib.zError(1));
    try testing.expectEqualStrings("need dictionary", zlib.zError(2));
    try testing.expectEqualStrings("file error", zlib.zError(-1));
    try testing.expectEqualStrings("stream error", zlib.zError(-2));
    try testing.expectEqualStrings("data error", zlib.zError(-3));
    try testing.expectEqualStrings("insufficient memory", zlib.zError(-4));
    try testing.expectEqualStrings("buffer error", zlib.zError(-5));
    try testing.expectEqualStrings("incompatible version", zlib.zError(-6));
}
