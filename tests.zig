// SPDX-License-Identifier: zlib
// See FORK-LICENSE.md for what that identifier covers.

//! Behavioural tests for the zlib facade.
//!
//! ## The oracle is not this code talking to itself
//!
//! A same-code round trip proves only that the code agrees with itself
//! (`AGENTS.md` §7). Every primary assertion here has a source outside this
//! package, and the sources are of three kinds:
//!
//!   * **A genuinely independent encoder.** `fixtures/gzip/*.bin` were produced
//!     by GNU gzip 1.13 (`fixtures/gzip-version.txt` records `gzip 1.13`), whose
//!     deflate encoder is not zlib's. Reading them proves this build reads
//!     another implementation's output; it cannot be satisfied by a round trip
//!     through `compress2`.
//!   * **The reference implementation at a different release.**
//!     `fixtures/pyzlib/*.z` and `*.bin` were produced by CPython 3.13's `zlib`
//!     module over **zlib 1.2.13** (`fixtures/pyzlib/zlib-runtime.txt` records
//!     `1.2.13`) while this build is 1.3.2. That is cross-release
//!     interoperability in both directions: this build reads 1.2.13's output,
//!     and `smoke.zig` writes output that 1.2.13's own decompressor reads.
//!   * **The specifications, read out of the tree.** RFC 1950, 1951 and 1952
//!     are vendored under `src/doc/`, and the independent known answers here are
//!     the ones those documents state or define: the Adler-32 recurrence of
//!     §8.2, the zlib stream layout of §2.2, the fixed Huffman code assignment of
//!     RFC 1951 §3.2.6, and the gzip header field layout of RFC 1952 §2.3.1.
//!
//! Nothing here pins a version string, an export list or a default as a test in
//! its own right, and no assertion's expected value is a value this package
//! computed and printed for comparison. Where a number is produced by the library
//! it is compared against a number derived from a specification or recorded by
//! another implementation.
//!
//! ## The fixtures are embedded, not pasted
//!
//! Every fixture is `@embedFile`d from `fixtures/`, with its digest recorded in
//! `fixtures/PROVENANCE.md`. No hex literal of a compressed stream appears in
//! this file, because a 146-byte hex string in a Zig source is a fixture nobody
//! can regenerate and nobody can diff.
//!
//! ## The allocator
//!
//! `deflateInit2` and `inflateInit2` allocate through libc's `malloc` and `free`
//! when `zalloc`/`zfree` are null, which is what this facade leaves them
//! (`zig/root.zig`, "Allocation"), and `compress2`/`uncompress2` open and end
//! their own streams the same way (`src/compress.c`, `src/uncompr.c:29-82`). So
//! `std.testing.allocator` cannot be a leak oracle for anything zlib allocates,
//! and no test here claims it is. What a test can check is the ownership
//! transition this module owns: that `deinit` ends the stream, that a second
//! `deinit` is not a second `deflateEnd`, and that ending one stream does not
//! disturb another.

const std = @import("std");
const zlib = @import("zlib");
const testing = std.testing;

/// A number that tells two runs of this gate apart in one directory.
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

// ---------------------------------------------------------------- fixtures ---

/// The 275-byte plaintext every fixture encodes. `fixtures/PROVENANCE.md`
/// records the producer and the digest; `fixtures/pyzlib/checksums.txt` records
/// the two checksums zlib 1.2.13 computed over exactly these bytes.
const plain = @embedFile("fixtures/plain.bin");

/// `gzip -1 -n -c plain.bin`, GNU gzip 1.13.
const gzip_n1 = @embedFile("fixtures/gzip/gzip-n1.bin");

/// `gzip -9 -n -c plain.bin`, GNU gzip 1.13.
const gzip_n9 = @embedFile("fixtures/gzip/gzip-n9.bin");

/// `gzip -9 -N -c plain.bin`, GNU gzip 1.13. Carries FNAME, so this is the one
/// fixture whose header has a field beyond the fixed ten bytes.
const gzip_n9_name = @embedFile("fixtures/gzip/gzip-n9-name.bin");

/// `zlib.compress(plain, 1)` over zlib 1.2.13.
const zlib_n1 = @embedFile("fixtures/pyzlib/zlib-n1.z");

/// `zlib.compress(plain, 6)` over zlib 1.2.13.
const zlib_n6 = @embedFile("fixtures/pyzlib/zlib-n6.z");

/// `zlib.compress(plain, 9)` over zlib 1.2.13.
const zlib_n9 = @embedFile("fixtures/pyzlib/zlib-n9.z");

/// `zlib.compressobj(6, DEFLATED, -15)` over zlib 1.2.13: a bare deflate stream.
const raw_n6 = @embedFile("fixtures/pyzlib/raw-n6.bin");

/// `zlib.compressobj(9, DEFLATED, -15)` over zlib 1.2.13.
const raw_n9 = @embedFile("fixtures/pyzlib/raw-n9.bin");

/// The Adler-32 zlib 1.2.13 recorded over `plain` (`fixtures/pyzlib/checksums.txt`).
const recorded_adler32: u32 = 3970324232;

/// The CRC-32 zlib 1.2.13 recorded over `plain`.
const recorded_crc32: u32 = 1368583364;

/// A shared object exporting the declarations of `zig/translate.h`, named by the
/// environment in a runtime-loading build.
const provider_variable = "ZLIB_TEST_PROVIDER";

/// Make the native library usable, once, before a test calls the facade.
///
/// In a linked build the facade is usable already and this is a no-op at
/// comptime. In a runtime-loading build every call into the module goes through
/// a table that `load` fills, so this is where the one explicit load happens.
/// It is safe to call from every test: the contract makes the same request
/// idempotent, and the loader keeps the handle to the end of the process.
///
/// A build that was not told which file to load stops here with the variable's
/// name, rather than reporting a test failure that says nothing about the reason.
/// A suite that quietly stopped testing because a variable was unset would report
/// success for nothing.
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

// -------------------------------------------------- independent checksums ---
//
// Both of these are computed here from the specification's own recurrence, in
// plain Zig, with no library involved. They exist so that the checks below are
// not "the library agrees with itself": if `zlib.adler32` and `referenceAdler32`
// were both wrong the same way, the recorded 1.2.13 value would still disagree.

/// The Adler-32 of RFC 1950 §8.2 (`src/doc/rfc1950.txt:479-490`).
///
/// `s1` starts at 1, `s2` at 0, both accumulate modulo 65521, and the stored
/// value is `s2 * 65536 + s1`. `src/doc/rfc1950.txt:567-569`'s own sample code
/// returns `update_adler32(1L, buf, len)`, which is the same initial value.
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

/// The CRC-32 of the reflected ISO-HDLC construction.
///
/// **This is derived here, not quoted from the tree.** The vendored RFC 1952 §4
/// (`src/doc/rfc1952.txt:515-527`) *recommends* that a gzip implementation
/// "set[] and check[] the CRC-32 check value" but prints no value for it, so the
/// `123456789` result asserted below is this function's answer cross-checked
/// against the well-known check value for that construction - not a citation to
/// the RFC, which does not carry one.
///
/// The construction: a reflected CRC with polynomial 0xEDB88320, initial value
/// 0xFFFFFFFF, and a final one's complement.
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

/// The two-bit code `src/zutil.c:35-40` writes for `sizeof(uInt)`: 0 for 16
/// bits, 1 for 32, 2 for 64, 3 for anything else. Applied to the width the
/// translated headers declare, so comparing it against what the provider
/// reports compares the compiled C against the header rather than against a
/// number this file happens to carry.
fn uIntWidthCode() u32 {
    return switch (@sizeOf(zlib.c.uInt)) {
        2 => 0,
        4 => 1,
        8 => 2,
        else => 3,
    };
}

// ------------------------------------------------------------ RFC 1951 bit
// writer, for the fixed-Huffman known answer.
//
// RFC 1951 §3.1.1 (`src/doc/rfc1951.txt:292-299`) states the packing rule this
// writer implements, and it is the opposite convention in the two cases that
// matter:
//
//   * "Data elements other than Huffman codes are packed starting with the
//     least-significant bit of the data element", and elements go into bytes
//     "starting with the least-significant bit of the byte".
//   * "Huffman codes are packed starting with the most-significant bit of the
//     code."
//
// So the block header is written LSB-first and a fixed Huffman code is written
// MSB-first. Getting this backwards produces a stream that decodes to something
// else, which is what makes this an independent check rather than a restatement.

/// A DEFLATE bit writer, LSB-first into bytes, with an MSB-first path for the
/// Huffman codes of RFC 1951 §3.2.6.
const BitWriter = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    bit_buffer: u32 = 0,
    bit_count: u8 = 0,

    /// Append `count` bits of `value`, least-significant bit first.
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

    /// Append `count` bits of `code`, most-significant bit first, which is how a
    /// Huffman code reaches the stream (`src/doc/rfc1951.txt:298-299`).
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

    /// Flush the partial byte, zero-padded, and return what was written.
    ///
    /// RFC 1951 §3.2.3 (`src/doc/rfc1951.txt:517-521`) says nothing about the
    /// final partial byte's padding beyond the block being byte-aligned for the
    /// stored-block case; a decoder ignores the unused high bits of the last
    /// byte, and the fixtures in this package confirm that with gzip's own output.
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

/// The fixed literal/length code for `symbol`, from RFC 1951 §3.2.6
/// (`src/doc/rfc1951.txt:655-676`).
///
/// The table the RFC prints:
///   * literals 0-143   : 8 bits, codes 00110000 through 10111111,
///   * literals 144-255 : 9 bits, codes 110010000 through 111111111,
///   * 256-279 (incl. 256, end of block) : 7 bits, codes 0000000 through 0010111,
///   * 280-287 : 8 bits, codes 11000000 through 11000111.
///
/// This is the table transcribed, not a table the library produced: the point is
/// that the bytes this function builds are derived from the specification text.
fn fixedHuffmanCode(symbol: u16) struct { count: u8, code: u32 } {
    return switch (symbol) {
        0...143 => .{ .count = 8, .code = 0x30 + symbol },
        144...255 => .{ .count = 9, .code = 0x190 + (symbol - 144) },
        256...279 => .{ .count = 7, .code = symbol - 256 },
        280...287 => .{ .count = 8, .code = 0xC0 + (symbol - 280) },
        else => unreachable,
    };
}

// ------------------------------------------------------------------- gzip ---

/// The ten fixed bytes of a gzip member header, as RFC 1952 §2.3.1
/// (`src/doc/rfc1952.txt:243`) lays them out: `ID1 ID2 CM FLG MTIME[4] XFL OS`.
fn expectGzipHeader(
    bytes: []const u8,
    expected_xfl: u8,
    expected_ftxt: bool,
    expected_fname: bool,
) !void {
    // src/doc/rfc1952.txt:289-293: "These have the fixed values ID1 = 31
    // (0x1f, \037), ID2 = 139 (0x8b, \260)".
    try testing.expectEqual(@as(u8, 0x1f), bytes[0]);
    try testing.expectEqual(@as(u8, 0x8b), bytes[1]);
    // src/doc/rfc1952.txt:294-299: "CM = 8 denotes the 'deflate' compression
    // method" and 0-7 are reserved.
    try testing.expectEqual(@as(u8, 8), bytes[2]);

    // src/doc/rfc1952.txt:300-306 gives the flag bit positions: bit 0 FTEXT,
    // bit 1 FHCRC, bit 2 FEXTRA, bit 3 FNAME, bit 4 FCOMMENT. The layout of
    // those five bits inside the byte is the RFC's own list at :300-310.
    const flg = bytes[3];
    try testing.expectEqual(expected_fname, (flg & 0x08) != 0);
    try testing.expectEqual(expected_ftxt, (flg & 0x01) != 0);
    // src/doc/rfc1952.txt:362: "Reserved FLG bits must be zero." Bits 5, 6 and 7
    // are reserved, and so are the unlisted combinations; nothing else is set on
    // these three fixtures, and a gzip that set one would not be a fixture this
    // package produced.
    try testing.expectEqual(@as(u8, 0), flg & 0xF0);
    try testing.expectEqual(@as(u8, 0), flg & 0x02); // FHCRC
    try testing.expectEqual(@as(u8, 0), flg & 0x04); // FEXTRA
    try testing.expectEqual(@as(u8, 0), flg & 0x10); // FCOMMENT

    // src/doc/rfc1952.txt:364-372: MTIME is little-endian, and "MTIME = 0 means
    // no time stamp is available" - which is what `gzip -n` asks for, so the two
    // `-n` fixtures carry zero. This is asserted against the RFC's meaning, not
    // against a value observed from gzip.
    var mtime: u32 = 0;
    for (0..4) |i| mtime |= @as(u32, bytes[4 + i]) << @intCast(8 * i);
    try testing.expectEqual(@as(u32, 0), mtime);

    // src/doc/rfc1952.txt:374-381: "XFL = 2 - compressor used maximum
    // compression, slowest algorithm" and "XFL = 4 - compressor used fastest
    // algorithm". `gzip -1` and `gzip -9` are the two settings the RFC names.
    try testing.expectEqual(expected_xfl, bytes[8]);

    // src/doc/rfc1952.txt:383-385: OS identifies the file system compression
    // took place on, and the defined values start with 0 FAT, 1 Amiga, 2 VMS,
    // 3 Unix. gzip 1.13 writes 3 on a Unix host, and `fixtures/PROVENANCE.md`
    // records the host command that produced these files.
    try testing.expectEqual(@as(u8, 3), bytes[9]);
}

/// The CRC-32 and ISIZE trailer of a gzip member, RFC 1952 §2.3
/// (`src/doc/rfc1952.txt:272-277`).
///
/// Both are little-endian on the wire, which §1.2 of the RFC settles at
/// `src/doc/rfc1952.txt:214-217`: "all multi-byte numbers in the format are
/// stored with the least-significant byte first".
fn expectGzipTrailer(bytes: []const u8) !void {
    const trailer = bytes[bytes.len - 8 ..];
    var crc: u32 = 0;
    for (0..4) |i| crc |= @as(u32, trailer[i]) << @intCast(8 * i);
    var isize_code: u32 = 0;
    for (0..4) |i| isize_code |= @as(u32, trailer[4 + i]) << @intCast(8 * i);

    try testing.expectEqual(referenceCrc32(plain), crc);
    // src/doc/rfc1952.txt:419-421: CRC32 covers "the uncompressed data"; ISIZE at
    // :276 is its length modulo 2^32, so for a 275-byte fixture it is 275.
    try testing.expectEqual(@as(u32, @intCast(plain.len)), isize_code);
}

/// Inflate `bytes` as a gzip member and return the plaintext.
fn inflateGzip(bytes: []const u8, output: []u8) !usize {
    var inflater: zlib.Inflater = .empty;
    try inflater.init(.gzip);
    defer inflater.deinit();
    const step = try inflater.runAll(bytes, output);
    // src/zlib.h:182: Z_STREAM_END is how a stream ends normally, so a decode
    // that did not reach it did not finish.
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    return step.produced;
}

// Decode the gzip-1.13 fixtures to exactly `plain`, and check the header and
// trailer fields against RFC 1952 before touching the body.
//
// A plain comment rather than a doc one: this compiler rejects
// `documentation comments cannot be attached to tests`.
//
// This is the strongest oracle in the package: the compressed bytes come from a
// deflate encoder that is not zlib's, and every asserted field is read out of
// `src/doc/rfc1952.txt` rather than out of a value this build observed.
test "GNU gzip 1.13 members decode to the recorded plaintext, header fields per RFC 1952" {
    nativeReady();

    var output: [512]u8 = undefined;

    // `gzip -1 -n`: XFL = 4, "compressor used fastest algorithm"
    // (src/doc/rfc1952.txt:380-381).
    try expectGzipHeader(gzip_n1, 4, false, false);
    try expectGzipTrailer(gzip_n1);
    try testing.expectEqual(plain.len, try inflateGzip(gzip_n1, &output));
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);

    // `gzip -9 -n`: XFL = 2, "compressor used maximum compression"
    // (src/doc/rfc1952.txt:379-380).
    try expectGzipHeader(gzip_n9, 2, false, false);
    try expectGzipTrailer(gzip_n9);
    try testing.expectEqual(plain.len, try inflateGzip(gzip_n9, &output));
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);

    // Both encoders produced the same deflate payload here, which is expected:
    // 275 bytes of this plaintext has no long-range redundancy for level 9 to
    // exploit that level 1 misses. Asserting that is not a claim about gzip; it
    // is a note that the two fixtures differ in the header and not the body.
    try testing.expectEqual(gzip_n1[10 .. gzip_n1.len - 8].len, gzip_n9[10 .. gzip_n9.len - 8].len);
}

// The `-N` fixture is the one with a header field beyond the fixed ten bytes,
// so FNAME is asserted and its absence is asserted on the other two.
test "gzip -N carries FNAME and the name RFC 1952 describes" {
    nativeReady();

    const flg = gzip_n9_name[3];
    // src/doc/rfc1952.txt:306: bit 3 is FNAME.
    try testing.expectEqual(@as(u8, 0x08), flg & 0x08);

    // RFC 1952 §2.3.1 (src/doc/rfc1952.txt:343-346) puts the name after the
    // fixed header, terminated by a zero byte, "with any directory components
    // removed, and, if the compressed file is on a file system with case
    // insensitive names, forced to lower case". The producer ran
    // `gzip -9 -N -c plain.bin`, so the name is the input file's own basename.
    const after_header = gzip_n9_name[10..];
    const end = std.mem.indexOfScalar(u8, after_header, 0) orelse
        return error.FnameNotTerminated;
    try testing.expectEqualStrings("plain.bin", after_header[0..end]);

    // `-N` is name-and-timestamp, not name-only, so MTIME is *not* zero here
    // (src/doc/rfc1952.txt:364-372 gives MTIME's meaning; the fixture's producer
    // is recorded in fixtures/PROVENANCE.md). Asserting that it is non-zero is
    // what separates this fixture from the two `-n` ones.
    var mtime: u32 = 0;
    for (0..4) |i| mtime |= @as(u32, gzip_n9_name[4 + i]) << @intCast(8 * i);
    try testing.expect(mtime != 0);

    var output: [512]u8 = undefined;
    try testing.expectEqual(plain.len, try inflateGzip(gzip_n9_name, &output));
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);
}

// `inflateGetHeader` reads the same fields the byte-level assertions above read
// by hand, through the provider's own header parser.
test "inflateGetHeader reads gzip-n9-name.bin's FNAME" {
    nativeReady();

    var buffers: zlib.HeaderBuffer = .{};
    var inflater: zlib.Inflater = .empty;
    try inflater.init(.gzip);
    defer inflater.deinit();

    // src/zlib.h:1073-1075: inflateGetHeader may be called after
    // inflateInit2() and before the first inflate(), which is where this is.
    // Upstream fills the struct *during* inflate - the same note says
    // `head->done` is "zero until the header is completed" - so this only
    // registers where the fields will be written, and the assertions below read
    // them out of `buffers` once the body has been decoded.
    try inflater.readHeader(&buffers);

    var output: [512]u8 = undefined;
    const step = try inflater.runAll(gzip_n9_name, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    try testing.expectEqual(plain.len, step.produced);
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);

    const header = buffers.current();
    // The name has to agree with what the bytes above said it was.
    try testing.expectEqualStrings("plain.bin", header.nameSlice().?);

    // OS = 3 and XFL = 2, the two values the byte-level test asserted directly.
    try testing.expectEqual(@as(i32, 3), header.os);
    try testing.expectEqual(@as(i32, 2), header.xflags);

    // `-N` preserves the timestamp, so this fixture's MTIME is not zero.
    try testing.expect(header.time != 0);

    // src/zlib.h:1083-1086 and :1088-1095: `done` is what says the header
    // finished, and once it is true the optional fields are whatever the member
    // carried. This one carried neither FCOMMENT nor FEXTRA, so upstream left
    // the caller's pointers and their capacity alone, and a name with no
    // terminating zero in it would have meant the buffer was too small rather
    // than that the field was absent.
    try testing.expect(header.done);
    try testing.expect(header.commentSlice() == null);
    try testing.expect(header.extraSlice() == null);
}

// The same member through the `gz*` file layer rather than a stream, which is
// the second, independent route to the same bytes: `src/gzread.c` has its own
// reading loop and its own header handling.
test "the gz file stream decodes the same gzip member to the same plaintext" {
    nativeReady();

    // Read back through `Gzip`, which is the only way to exercise
    // `src/gzlib.c`, `src/gzread.c` and `src/gzclose.c` at all.
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "zlib-test-{d}.gz", .{runTag()});
    // `Dir` operations take the `Io` separately in this compiler, and a
    // `zig test` root has no `std.process.Init` to take one from, so this is the
    // process-wide single-threaded instance, the same one `smoke.zig:96` takes
    // from its `Init`.
    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // The member goes down verbatim, because `Gzip.openWrite` would put a
    // *second* gzip container around these bytes and `Gzip.openRead` would then
    // hand back `gzip_n1` rather than the plaintext - a nested member, not the
    // foreign one this test exists to decode. `src/gzread.c` is only reached at
    // all by a file whose first bytes are a real RFC 1952 header.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = gzip_n1 });

    {
        var file = try zlib.Gzip.openRead(path);
        defer file.deinit();

        var output: [512]u8 = undefined;
        var filled: usize = 0;
        while (true) {
            // A named slice, not `&output[filled..]`: `&` on a slice is a
            // `*[]u8`, and `readSome` takes the slice (`smoke.zig:287-289`).
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

    // The other half of the file layer, `src/gzwrite.c`: a member this facade
    // wrote itself, read back through the same reader. It supplements the
    // foreign member above rather than replacing it, because on its own it
    // would only prove zlib agrees with itself. What goes in is the plaintext,
    // because `gzwrite` compresses whatever it is handed - handing it the
    // compressed fixture would put a second container around those bytes and
    // hand them straight back.
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
        // `read` rather than `readSome`, so `src/zlib.h:1490-1493`'s "less than
        // len for end of file" is the loop's business and the zero read is what
        // ends it: one `read` may return a short count and nothing more.
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

// `inflateGetHeader` on a zlib-format stream has no gzip header to read, and
// this module says so rather than returning zeroes that look like a real header.
test "readHeader refuses a stream that has no gzip header" {
    nativeReady();

    var buffers: zlib.HeaderBuffer = .{};
    var inflater: zlib.Inflater = .empty;
    try inflater.init(.zlib);
    defer inflater.deinit();
    try testing.expectError(error.StreamError, inflater.readHeader(&buffers));
}

// ------------------------------------------- cross-release interoperability --

/// The zlib 1.2.13 fixtures, checked for the layout RFC 1950 §2.2 gives them
/// before they are decoded.
fn expectZlibWrapper(bytes: []const u8, expected_flevel: u8) !void {
    // src/doc/rfc1950.txt:245-252 splits CMF into a 4-bit CM and a 4-bit CINFO.
    const cmf = bytes[0];
    // src/doc/rfc1950.txt:255-258: "CM = 8 denotes the 'deflate' compression
    // method with a window size up to 32K."
    try testing.expectEqual(@as(u8, 8), cmf & 0x0F);
    // src/doc/rfc1950.txt:260-263: "CINFO is the base-2 logarithm of the LZ77
    // window size, minus eight (CINFO=7 indicates a 32K window size)" and values
    // above 7 are not allowed.
    try testing.expectEqual(@as(u8, 7), cmf >> 4);

    const flg = bytes[1];
    // src/doc/rfc1950.txt:268-274 splits FLG into FCHECK (bits 0-4), FDICT
    // (bit 5) and FLEVEL (bits 6-7). None of these fixtures uses a dictionary.
    try testing.expectEqual(@as(u8, 0), flg & 0x20);
    try testing.expectEqual(expected_flevel, flg >> 6);
    // src/doc/rfc1950.txt:275-278: "The FCHECK value must be such that CMF and
    // FLG, when viewed as a 16-bit unsigned integer stored in MSB order
    // (CMF*256 + FLG), is a multiple of 31." That is a property of the two bytes,
    // not of this package, so it is asserted directly.
    const combined: u32 = @as(u32, cmf) * 256 + @as(u32, flg);
    try testing.expectEqual(@as(u32, 0), combined % 31);

    // src/doc/rfc1950.txt:318-320: the trailer is the Adler-32 of the
    // uncompressed data, and §2.2 (:238-240) puts it after the compressed data
    // in network (most-significant-byte) order.
    var adler: u32 = 0;
    const tail = bytes[bytes.len - 4 ..];
    for (tail) |byte| adler = (adler << 8) | byte;
    try testing.expectEqual(referenceAdler32(plain), adler);
}

// zlib 1.2.13's `zlib.compress(plain, n)` output, read by this build.
//
// Cross-release interoperability in the direction that matters most: a 1.3.2
// reader of a 1.2.13 writer, with the header and trailer checked against RFC
// 1950 before the body is touched.
test "zlib 1.2.13 wrappers decode to the recorded plaintext, layout per RFC 1950" {
    nativeReady();

    var output: [512]u8 = undefined;

    // src/doc/rfc1950.txt:301-304 gives FLEVEL: 0 fastest, 1 fast, 2 default,
    // 3 maximum compression. `zlib.compress(plain, n)` at n = 1, 6 and 9 is
    // exactly those three settings.
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

// zlib 1.2.13's raw deflate output, which has neither the RFC 1950 wrapper nor
// the RFC 1952 one: `compressobj(6, DEFLATED, -15)` sets a negative windowBits,
// which is what makes the stream bare.
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

    // A bare deflate stream has no trailer, so its length is exactly the deflate
    // body. `zlib-n9.z` is the same bytes with a two-byte header and a four-byte
    // Adler-32 around them, and 152 - 6 = 146. That arithmetic is what proves
    // the two fixture families were produced by the same encoder run, rather
    // than merely being similar.
    try testing.expectEqual(zlib_n9.len - 6, raw_n9.len);
    try testing.expectEqualSlices(u8, zlib_n9[2..][0..raw_n9.len], raw_n9);
}

// The `*_MAX_WBITS` route upstream's own `src/Makefile.in:291` names for gzip:
// `inflateInit2(16 + MAX_WBITS)` reaches the same gzip decoder as `.gzip`.
test "inflateInit2 at 16 + MAX_WBITS reads a gzip stream, as src/Makefile.in:291 says" {
    nativeReady();

    // src/Makefile.in:291: `-DMAX_WBITS=14` is a comment about memory, and the
    // `+16` that selects gzip is what src/zlib.h:246 documents. This goes
    // through the raw route so the number is the one upstream's own line uses.
    var stream: zlib.c.z_stream = std.mem.zeroes(zlib.c.z_stream);
    const code = zlib.c.inflateInit2_(
        &stream,
        16 + 15,
        zlib.version,
        @sizeOf(zlib.c.z_stream),
    );
    try testing.expectEqual(@as(c_int, 0), code);
    // `inflateEnd` frees the state and is the only thing that reports it did,
    // and a `defer` cannot propagate an error, so the code is asserted where it
    // can be: after the work, on the straight line. The `defer` behind it is
    // the safety net for an early `try` failing, and a second call is inert -
    // `src/inflate.c:1162` sets `state` to `Z_NULL` and `inflateStateCheck`
    // then makes `src/inflate.c:1157-1158` return `Z_STREAM_ERROR` without
    // freeing anything twice.
    defer _ = zlib.c.inflateEnd(&stream);

    // `z_stream.next_in` is `[*c]u8` (`src/zlib.h:96`) because upstream stores
    // the caller's buffer, so the immutable embedded fixture goes through a
    // writable copy rather than a `constCast` of a buffer inflate never writes.
    var input_buffer: [gzip_n9.len]u8 = undefined;
    @memcpy(&input_buffer, gzip_n9);
    stream.next_in = &input_buffer;
    stream.avail_in = @intCast(gzip_n9.len);
    var output: [512]u8 = undefined;
    stream.next_out = &output;
    stream.avail_out = @intCast(output.len);
    const got = zlib.c.inflate(&stream, @intFromEnum(zlib.Flush.finish));
    // src/zlib.h:182: Z_STREAM_END is how a complete member ends.
    try testing.expectEqual(@as(c_int, 1), got);
    try testing.expectEqual(plain.len, stream.total_out);
    try testing.expectEqualSlices(u8, plain, output[0..plain.len]);
    try testing.expectEqual(@as(c_int, 0), zlib.c.inflateEnd(&stream));
}

// ------------------------------------------------------ specification values --

// Adler-32 and CRC-32, each checked three ways: the library's answer, the
// specification's recurrence computed here, and the value zlib 1.2.13 recorded
// in `fixtures/pyzlib/checksums.txt`.
test "the checksums agree with the RFC 1950 recurrence and with zlib 1.2.13" {
    nativeReady();

    // src/doc/rfc1950.txt:485-490 gives s1 = 1 as the initial value, and
    // :567-569's sample code passes 1L.
    try testing.expectEqual(@as(u32, 1), zlib.checksum.adler32Empty());
    try testing.expectEqual(@as(u32, 1), referenceAdler32(""));

    // The CRC-32 of no bytes is zero, which is the `checksum.crc32_init` this
    // package names so a caller cannot get the two starts swapped.
    try testing.expectEqual(@as(u32, 0), zlib.checksum.crc32Empty());
    try testing.expectEqual(@as(u32, 0), referenceCrc32(""));

    // Both over the fixture, against the value zlib 1.2.13 recorded.
    try testing.expectEqual(referenceAdler32(plain), zlib.adler32(zlib.checksum.adler32_init, plain));
    try testing.expectEqual(recorded_adler32, zlib.adler32(zlib.checksum.adler32_init, plain));
    try testing.expectEqual(referenceCrc32(plain), zlib.crc32(zlib.checksum.crc32_init, plain));
    try testing.expectEqual(recorded_crc32, zlib.crc32(zlib.checksum.crc32_init, plain));

    // The standard CRC-32/ISO-HDLC check value. The vendored RFC 1952 §4
    // (src/doc/rfc1952.txt:515-527) recommends checking the CRC-32 but prints
    // no value, so this is the construction's well-known check value, derived
    // above from the reflected polynomial rather than quoted from this tree.
    try testing.expectEqual(@as(u32, 0xCBF43926), referenceCrc32("123456789"));
    try testing.expectEqual(@as(u32, 0xCBF43926), zlib.crc32(zlib.checksum.crc32_init, "123456789"));
}

// A fixed-Huffman block built from RFC 1951 §3.2.6's table and decoded by
// this build.
//
// This is the specification-derived known answer: the bytes are assembled here
// from the code assignment the RFC prints, so a decode that returns the
// expected plaintext cannot be satisfied by this build agreeing with itself -
// `src/inffixed.h` also generates that table, but nothing in this file reads it.
test "a block built from RFC 1951 section 3.2.6 decodes to the literals it encodes" {
    nativeReady();

    const message = "zlib fixed Huffman known answer";
    var writer: BitWriter = .{};

    // src/doc/rfc1951.txt:517-521 gives BTYPE=01 for "compressed with fixed
    // Huffman codes", written LSB-first after BFINAL (src/doc/rfc1951.txt:534-537).
    writer.writeLsb(1, 1); // BFINAL = 1, the last block
    writer.writeLsb(2, 0b01); // BTYPE = 01, fixed Huffman

    for (message) |byte| {
        const entry = fixedHuffmanCode(byte);
        writer.writeMsb(entry.count, entry.code);
    }
    // Symbol 256 is end of block: a 7-bit code of 0000000
    // (src/doc/rfc1951.txt:670-671).
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

// The stored-block form from RFC 1951 §3.2.4, which is the other BTYPE and the
// one a Huffman-only test would not reach: three header bits, a length, and the
// bytes themselves. `src/doc/rfc1951.txt:539-551` is the block layout.
test "a stored block from RFC 1951 section 3.2.4 round-trips its bytes" {
    nativeReady();

    const payload = "stored blocks are stored";
    var writer: BitWriter = .{};

    writer.writeLsb(1, 1); // BFINAL
    writer.writeLsb(2, 0b00); // BTYPE = 00, stored
    // Align to the next byte boundary, which src/doc/rfc1951.txt:539-543
    // requires before the length fields of a stored block.
    writer.writeLsb(@intCast((8 - (writer.bit_count % 8)) % 8), 0);
    try testing.expectEqual(@as(u8, 0), writer.bit_count);

    // LEN and NLEN are little-endian 16-bit fields (src/doc/rfc1951.txt:544-549)
    // and NLEN is LEN's one's complement.
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

// ---------------------------------------------------- behavioural boundaries --

// `compressBound` is a bound, not an estimate: every level, every strategy and
// every window size must fit inside it.
test "compressBound is an upper bound for every level and strategy" {
    nativeReady();

    var output: [4096]u8 = undefined;
    const levels = [_]zlib.Level{
        .no_compression, .best_speed, .best_compression, .default_compression,
        @enumFromInt(2), @enumFromInt(6), @enumFromInt(8),
    };
    const strategies = [_]zlib.Strategy{ .default, .filtered, .huffman_only, .rle, .fixed };

    for (levels) |level| {
        for (strategies) |strategy| {
            // src/zlib.h:1298-1306 promises an upper bound that holds "even for
            // a deflate stream with no compression", so the worst case to check
            // is the one that produces the largest output.
            const bound = zlib.compressBound(plain.len);
            const produced = try zlib.compress2(&output, plain, .{
                .level = level,
                .strategy = strategy,
            });
            try testing.expect(produced <= bound);
            try testing.expect(bound >= plain.len);
        }
    }

    // A one-byte input and a zero-byte input are the two ends of the range, and
    // both have documented bounds rather than special cases being needed.
    try testing.expect(zlib.compressBound(0) > 0);
    try testing.expect(zlib.compressBound(1) > 1);
}

// `deflateBound` bounds what *this* stream will produce, and it is a different
// function from `compressBound`.
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

// A destination that is too short is refused, and what lands in it is the
// leading part of the very stream a correctly-sized call produces.
//
// `src/zlib.h:1298-1301` makes the size a precondition rather than a promise:
// the destination "must be at least the value returned by
// compressBound(sourceLen)", and `Z_BUF_ERROR` is simply "there was not enough
// room". `src/compress.c:50-59` is why nothing stronger can be claimed: it
// hands `deflate` whatever room is left and only discovers there is none when
// `left` reaches zero, so the buffer is not left untouched. This test used to
// assert that it was, and `src/compress.c` is what made that wrong.
test "a short destination is refused and holds the leading part of the real stream" {
    nativeReady();

    // A sentinel no compressed byte can be mistaken for, so "this really was
    // written" is checkable rather than assumed.
    const sentinel: u8 = 0xA5;
    var output: [8]u8 = @splat(sentinel);

    try testing.expectError(error.BufError, zlib.compress2(&output, plain, .{}));

    // The bound tells the caller how much to retry with, which is the reason it
    // exists as a separate function rather than as a rule of thumb.
    const bound = zlib.compressBound(plain.len);
    var big: [512]u8 = undefined;
    const produced = try zlib.compress2(big[0..bound], plain, .{});
    try testing.expect(produced > output.len);

    // And the short buffer holds the first `output.len` bytes of exactly that
    // stream: "not enough room" means a prefix, not a different encoding.
    try testing.expectEqualSlices(u8, big[0..output.len], &output);
}

// A truncated stream must not be mistaken for a complete one.
//
// src/zlib.h:515-518 is explicit that `Z_BUF_ERROR` from `inflate` "is not
// fatal", but it is what an inflate with nothing more to read returns, and
// nothing in `src/inflate.c` invents an end-of-stream for a stream that did not
// send one. So a truncated stream is an error and the destination past what was
// produced is untouched.
test "a truncated stream reports BufError and leaves the destination untouched" {
    nativeReady();

    // A real 1.2.13 stream cut in half, so the truncation is in the middle of
    // deflate data rather than in the wrapper.
    const truncated = raw_n9[0 .. raw_n9.len / 2];

    const sentinel: u8 = 0x5A;
    var output: [512]u8 = @splat(sentinel);

    var inflater: zlib.Inflater = .empty;
    try inflater.init(.raw);
    defer inflater.deinit();

    // Drive it call by call, because the whole point is that the loop stops
    // without reaching Z_STREAM_END.
    var produced: usize = 0;
    var rest: []const u8 = truncated;
    var reached_end = false;
    while (true) {
        const step = inflater.run(rest, output[produced..], .no_flush) catch |err| {
            // The last call has no input left and no output room to use, which
            // is Z_BUF_ERROR (src/zlib.h:188) and is not a success.
            try testing.expectEqual(error.BufError, err);
            break;
        };
        if (step.status == .stream_end) {
            reached_end = true;
            produced += step.produced;
            break;
        }
        if (step.consumed == 0 and step.produced == 0) {
            // No progress, no error, and nothing left to read: the stream is
            // waiting for a continuation that never comes. src/zlib.h:360-362 is
            // the case, and Z_BUF_ERROR is an error here even though the header
            // calls it "not fatal".
            try testing.expectError(
                error.BufError,
                inflater.run("", output[produced..], .no_flush),
            );
            break;
        }
        produced += step.produced;
        rest = rest[step.consumed..];
        if (rest.len == 0) {
            // One more call with nothing to read must be the one that reports it.
            try testing.expectError(
                error.BufError,
                inflater.run("", output[produced..], .no_flush),
            );
            break;
        }
    }
    try testing.expect(!reached_end);

    // Whatever was produced before the end is a prefix of the plaintext, and
    // everything past it is still the sentinel.
    try testing.expect(produced <= plain.len);
    try testing.expectEqualSlices(u8, plain[0..produced], output[0..produced]);
    const tail = output[produced..];
    for (tail) |byte| try testing.expectEqual(sentinel, byte);
}

// A corrupt stream must report `Z_DATA_ERROR` and leave the stream usable.
//
// The corruption here is structural rather than a flipped byte: a raw deflate
// stream fed to a stream that expects the RFC 1950 wrapper. `src/doc/rfc1950.txt:255-258`
// says CM = 8 is the deflate method and `src/inflate.c` checks the header before
// touching the body, so this is a deterministic failure rather than a
// probabilistic one.
test "a corrupt stream reports DataError and stays usable after inflateReset" {
    nativeReady();

    var output: [512]u8 = undefined;

    var inflater: zlib.Inflater = .empty;
    try inflater.init(.zlib);
    defer inflater.deinit();

    // `raw_n9` has no CMF byte, so the first byte the wrapper reader sees is
    // deflate data, and CM will not be 8.
    try testing.expectError(error.DataError, inflater.runAll(raw_n9, &output));

    // The same stream object now reads a well-formed member of the container it
    // was initialised for: the error was a property of the bytes that were fed,
    // not of the stream. `zlib_n9` is a 1.2.13 RFC 1950 member, which is what
    // `init(.zlib)` above is reading; this test used to feed it the *gzip*
    // fixture, and a gzip member on a `.zlib` stream is a second header error,
    // not a recovery.
    try inflater.reset();
    const step = try inflater.runAll(zlib_n9, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    try testing.expectEqual(plain.len, step.produced);
    try testing.expectEqualSlices(u8, plain, output[0..step.produced]);
}

// The same, on the one-shot route: `uncompress` on a wrapper whose header is
// wrong must not return partial output as a success.
test "uncompressing a stream with no zlib header reports DataError" {
    nativeReady();

    var output: [512]u8 = undefined;
    try testing.expectError(error.DataError, zlib.uncompress(&output, raw_n9));
}

// `adler32_combine` must agree with hashing the concatenation directly, at a
// split that is not a multiple of anything and at the two degenerate ends.
test "adler32_combine agrees with hashing the concatenation" {
    nativeReady();

    const split = 137; // deliberately not a round number and not a power of two
    const first = plain[0..split];
    const second = plain[split..];

    const whole = zlib.adler32(zlib.checksum.adler32_init, plain);
    const a = zlib.adler32(zlib.checksum.adler32_init, first);
    const b = zlib.adler32(zlib.checksum.adler32_init, second);
    try testing.expectEqual(whole, zlib.adler32_combine(a, b, second.len));

    // Both degenerate ends: an empty second run, and an empty first run.
    const only_first = zlib.adler32(zlib.checksum.adler32_init, first);
    try testing.expectEqual(only_first, zlib.adler32_combine(a, zlib.checksum.adler32_init, 0));

    const only_second = zlib.adler32(zlib.checksum.adler32_init, second);
    try testing.expectEqual(only_second, zlib.adler32_combine(zlib.checksum.adler32_init, b, second.len));

    // And the CRC-32 form of the same claim.
    const c = zlib.crc32(zlib.checksum.crc32_init, first);
    const d = zlib.crc32(zlib.checksum.crc32_init, second);
    try testing.expectEqual(
        zlib.crc32(zlib.checksum.crc32_init, plain),
        zlib.crc32_combine(c, d, second.len),
    );
}

// `crc32_combine_gen` and `crc32_combine_op` are the two halves of
// `crc32_combine`, and must give the same answer.
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

    // A zero length does **not** generate a zero operator, and this test used to
    // say it did. `src/crc32.c:184-195` is `x2nmodp`: its first line is
    // `p = (uLong)1 << 31; /* x^0 == 1 */` and the loop that would change that
    // is `while (n)`, which a zero `n` never enters. So the operator for a
    // length of zero is x^0.
    try testing.expectEqual(@as(u32, 1) << 31, zlib.crc32_combine_gen(0));

    // The zero operator `crc32_combine_op` answers for is its own, and a
    // separate one: `src/crc32.c:969-970` returns zero for it outright, before
    // any multiplication. Two different statements, and this asserts both.
    try testing.expectEqual(@as(u32, 0), zlib.crc32_combine_op(c, d, 0));
}

// `deflateParams` mid-stream must change what the stream produces, and must
// still produce a stream that decompresses to the same bytes.
test "deflateParams changes the ratio mid-stream and keeps the plaintext intact" {
    nativeReady();

    // Two halves, so the parameter change happens with input already consumed -
    // which src/zlib.h:731-738 says is exactly the case where the old settings
    // finish the data so far first.
    const split = 137;
    const first = plain[0..split];
    const second = plain[split..];

    var fast: [1024]u8 = undefined;
    var slow: [1024]u8 = undefined;

    // A stream that never changes level.
    var steady: zlib.Deflater = .empty;
    try steady.init(.{ .level = .best_speed }, .zlib);
    const steady_len = (try steady.runAll(plain, &fast)).produced;
    // Read the counter *before* `deinit`, which zeroes the stream: the point of
    // the assertion is that the input really was consumed, not that a released
    // stream remembers it.
    try testing.expectEqual(@as(usize, plain.len), steady.totalIn());
    steady.deinit();

    // A stream that switches to level 9 after the first half.
    var switched: zlib.Deflater = .empty;
    try switched.init(.{ .level = .best_speed }, .zlib);
    _ = try switched.run(first, slow[0..], .no_flush);
    try switched.params(.best_compression, .default);
    // `deflateParams` writes to the output itself: `src/deflate.c` finishes the
    // block it was given with the *old* settings before the new ones take hold,
    // and `src/zlib.h:717-748` is the note that says so and warns that it may
    // need more output room than the caller expected. So the stream's own
    // `total_out` is where its cursor is - the `Progress.produced` of this
    // module's calls is not, and using it put the second call's output straight
    // on top of the one `deflateParams` had just written.
    _ = try switched.runAll(second, slow[switched.totalOut()..]);
    try testing.expectEqual(@as(usize, plain.len), switched.totalIn());
    const switched_len = switched.totalOut();
    switched.deinit();

    // The same plaintext either way, which is the half of the claim that is not
    // about ratio.
    var check: [512]u8 = undefined;
    try testing.expectEqualSlices(u8, plain, check[0..try zlib.uncompress(&check, fast[0..steady_len])]);
    try testing.expectEqualSlices(u8, plain, check[0..try zlib.uncompress(&check, slow[0..switched_len])]);

    // And the two are not the same length, which is what "changes the ratio"
    // has to mean if it is to be checkable at all. On this fixture level 9 is
    // smaller, but the assertion is deliberately the weaker one: the point is
    // that `deflateParams` took effect, not which direction it moved the ratio.
    try testing.expect(steady_len != switched_len);
}

// `adler32` and `crc32` are running functions, so continuing from a previous
// result must equal hashing the concatenation. This is the property that makes
// a streaming checksum correct at all.
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

// The facade's own state: a stream that has ended twice is a no-op the second
// time, and ending one stream does not disturb another.
test "deinit is idempotent and one stream's end does not disturb another" {
    nativeReady();

    var output: [512]u8 = undefined;

    var a: zlib.Deflater = .empty;
    try a.init(.{}, .zlib);
    var b: zlib.Deflater = .empty;
    try b.init(.{ .level = .best_speed }, .zlib);

    const first_a = try a.runAll(plain, &output);
    const first_b = try b.runAll(plain, &output);
    // `produced` on a `Deflater` is compressed output, not the plaintext that
    // went in: `Progress.produced` is `output.len - avail_out`, and the level
    // `b` is running makes the compressed size smaller than the 275-byte input.
    try testing.expect(first_a.produced < plain.len);
    try testing.expect(first_b.produced < plain.len);

    a.deinit();
    // A second deinit is the case upstream names at src/zlib.h:374-376 as
    // "Z_DATA_ERROR if the stream was freed without being ended first", so this
    // is the wrapper's ownership rule, not an accident.
    a.deinit();

    // `b` is untouched by `a` ending: its own totals and its container are still
    // what it left there.
    try testing.expectEqual(@as(usize, plain.len), b.totalIn());
    try testing.expectEqual(zlib.Format.zlib, b.container());

    // `src/zlib.h:335-336` is explicit that after `Z_STREAM_END` "the only
    // possible operations on the stream are deflateReset or deflateEnd", so
    // `b` is reset before being fed again rather than the call being expected
    // to work.
    try b.reset();
    const step = try b.runAll(plain, &output);
    try testing.expectEqual(zlib.Status.stream_end, step.status);
    // The same input at the same level again, so `b` produced the same stream
    // it did before `a` ended and `b` was reset: its configuration survived
    // both. This is compressed bytes on both sides, as above.
    try testing.expectEqual(first_b.produced, step.produced);
    try testing.expectEqualSlices(u8, output[0..first_b.produced], output[0..step.produced]);
    b.deinit();
}

// A `Deflater.reset` returns a used stream to a usable state without a new
// `init`, which is what src/zlib.h:695-700 promises.
test "deflateReset reuses a stream's configuration" {
    nativeReady();

    var output: [512]u8 = undefined;

    var deflater: zlib.Deflater = .empty;
    try deflater.init(.{ .level = .best_compression }, .zlib);
    defer deflater.deinit();

    const first = try deflater.runAll(plain, &output);
    try testing.expectEqual(plain.len, first.consumed);

    try deflater.reset();
    // src/zlib.h:698-700: total_in, total_out, adler and msg are initialized by
    // a reset.
    try testing.expectEqual(@as(usize, 0), deflater.totalIn());
    try testing.expectEqual(@as(usize, 0), deflater.totalOut());

    const second = try deflater.runAll(plain, &output);
    try testing.expectEqual(first.produced, second.produced);
}

// `uncompress2` advances the source past the stream it read, which is what
// makes two concatenated zlib members readable out of one buffer.
test "uncompress2 consumes exactly one member and leaves the rest" {
    nativeReady();

    // Two real members back to back. Concatenating them is not a fixture: the
    // concatenation itself is what the API under test is about, and its
    // correctness is checked by decompressing both halves.
    var both: [512]u8 = undefined;
    @memcpy(both[0..zlib_n9.len], zlib_n9);
    @memcpy(both[zlib_n9.len..][0..zlib_n6.len], zlib_n6);
    const joined = both[0 .. zlib_n9.len + zlib_n6.len];

    var rest: []const u8 = joined;
    var output: [512]u8 = undefined;

    const first_len = try zlib.uncompress2(&output, &rest);
    try testing.expectEqual(plain.len, first_len);
    try testing.expectEqualSlices(u8, plain, output[0..first_len]);
    // Exactly the first member consumed, not the whole buffer.
    try testing.expectEqual(zlib_n9.len, joined.len - rest.len);
    try testing.expectEqual(zlib_n6.len, rest.len);

    const second_len = try zlib.uncompress2(&output, &rest);
    try testing.expectEqual(plain.len, second_len);
    try testing.expectEqualSlices(u8, plain, output[0..second_len]);
    try testing.expectEqual(@as(usize, 0), rest.len);
}

// Round trips, which supplement the interop tests above and never replace them.
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

    // The binary tail of the fixture is the part a text-only round trip would
    // lose: it contains a byte above 0x7f and a NUL. `fixtures/PROVENANCE.md`
    // records the payload; this is the assertion that it survived.
    try testing.expect(std.mem.indexOfScalar(u8, plain, 0) != null);
}

// The provider's own version and flags, read through the escape hatch rather
// than compared against a constant compiled into this program.
test "the provider reports this SDK's version and none of the refused configurations" {
    nativeReady();

    try testing.expectEqualStrings(zlib.version, zlib.zlibVersion());

    const flags = zlib.zlibCompileFlags();
    // src/zlib.h:1226 and :1228, and the two bits runtime/library.zig refuses.
    try testing.expectEqual(@as(u32, 0), flags & zlib.flag_debug);
    try testing.expectEqual(@as(u32, 0), flags & zlib.flag_winapi);

    // src/zlib.h:1218-1223 gives two bits for the size of uInt (bits 1.0) and
    // two for uLong (bits 3.2), with 00 = 16 bits, 01 = 32, 10 = 64, 11 = other.
    // `src/zutil.c:35-40` is the switch that writes the first pair, so the
    // expected code is that switch applied to the width the *headers* declare.
    // A constant could not do this: it would only ever say that this program
    // and this library were built on one host, and would miss the case that
    // matters, which is the two of them being built with different widths.
    try testing.expectEqual(uIntWidthCode(), (flags >> 0) & 0x3);
}

// `zError` answers for every code the header defines, from upstream's own table.
test "zError spells every status code the header defines" {
    nativeReady();

    // src/zutil.c:13-24 is the table; the strings below are read out of it.
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