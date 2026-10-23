// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.

//! Zig facade over zlib; `c` exposes the translated C declarations.

const std = @import("std");

/// The translated zlib headers. Use `c` for declarations not wrapped here.
/// Runtime-loaded builds route its exported declarations through the dispatch.
pub const c = @import("c");

/// Loader core for the linked configuration.
const rt = @import("rt");

/// Whether this build resolves native symbols at run time.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// A file path or platform-loader name; neither source falls back to the other.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned by `load`.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the requested native library in a runtime-loaded build.
/// Returns `LoadError`; successful loads retain the handle for the process lifetime.
pub fn load(source: LoadSource) LoadError!void {
    // The comptime branch avoids requiring `c.load` in linked builds.
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "zlib: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with runtime " ++
            "loading configured, or do not call load.",
        .{},
    );
}

/// The successful request, retained for the process lifetime; null when unloaded.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// The header bytes used to derive this module's version constants.
const zlib_header = @import("zlib_header").bytes;

/// Maximum sentinel-terminated header string length; oversized values fail at comptime.
const version_string_max = 32;

/// Extracts a string macro from the embedded header; missing or oversized values fail at comptime.
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

/// Parses a decimal or hexadecimal integer macro from the embedded header.
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

/// The release string read from `src/zlib.h`.
const version_array = headerString("ZLIB_VERSION");
/// Returns the bytes before the first NUL in `array`.
fn trimmed(comptime array: anytype) [:0]const u8 {
    const at = comptime std.mem.indexOfScalar(u8, &array, 0) orelse unreachable;
    return array[0..at :0];
}
pub const version: [:0]const u8 = trimmed(version_array);

/// The packed release number read from `src/zlib.h`.
pub const version_num: u32 = @intCast(headerInt("ZLIB_VERNUM"));

/// Returns the provider's version string as a borrow from library storage.
pub fn zlibVersion() [:0]const u8 {
    return std.mem.span(c.zlibVersion());
}

/// Returns the provider's compile-time configuration flags.
/// Bits 8 and 10 identify configurations rejected by `runtime/library.zig`.
pub fn zlibCompileFlags() u32 {
    // C `unsigned long` width varies by target.
    const raw: c_ulong = c.zlibCompileFlags();
    return @truncate(raw);
}

/// Bit 8: the provider was built with `ZLIB_DEBUG`.
pub const flag_debug: u32 = 1 << 8;

/// Bit 10: provider functions use the `WINAPI` calling convention.
pub const flag_winapi: u32 = 1 << 10;

/// Every status code defined by `src/zlib.h:181-189`.
/// Negative values are failures; positive values are events.
pub const Status = enum(c_int) {
    /// `Z_OK`: success.
    ok = 0,
    /// `Z_STREAM_END`: normal stream completion.
    stream_end = 1,
    /// `Z_NEED_DICT`: a preset dictionary is required.
    need_dict = 2,
    /// `Z_ERRNO`: a file error; consult `errno`.
    errno = -1,
    /// `Z_STREAM_ERROR`: inconsistent state or an invalid parameter.
    stream_error = -2,
    /// `Z_DATA_ERROR`: corrupt input.
    data_error = -3,
    /// `Z_MEM_ERROR`: insufficient memory.
    mem_error = -4,
    /// `Z_BUF_ERROR`: no progress was possible.
    buf_error = -5,
    /// `Z_VERSION_ERROR`: library and headers disagree about the version.
    version_error = -6,

    /// Returns the matching error, or null for `ok` and `stream_end`.
    /// Unknown integer values are rejected by `statusOf`.
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

/// Errors returned by zlib and additional conditions reported by this facade.
pub const Error = error{
    /// `Z_NEED_DICT`: the stream requires a preset dictionary.
    NeedDict,
    /// `Z_ERRNO`: file error; consult `errno` for details.
    Errno,
    /// `Z_STREAM_ERROR`: inconsistent stream state or invalid parameters.
    StreamError,
    /// `Z_DATA_ERROR`: corrupt input; decompression may have produced partial output.
    DataError,
    /// `Z_MEM_ERROR`: insufficient memory.
    MemError,
    /// `Z_BUF_ERROR`: no progress was possible, often because a buffer is too small.
    BufError,
    /// `Z_VERSION_ERROR`: library and headers disagree about the version.
    VersionError,

    /// A status value not named by this SDK.
    UnknownStatus,
    /// `gzopen` returned null; zlib does not distinguish open failure from allocation failure.
    OpenFailed,
    /// `gzread` reached end of input.
    EndOfInput,
    /// `gzwrite` wrote nothing for a non-empty request.
    NotWritable,
};

/// Converts a raw zlib status code, returning `UnknownStatus` for unknown values.
pub fn statusOf(code: c_int) Error!Status {
    // Validate before `@enumFromInt` so unknown values become `UnknownStatus`.
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

/// Returns zlib's message for a status code, clamping to its documented range.
/// The result borrows the library's static message table.
pub fn zError(code: c_int) [:0]const u8 {
    const clamped = std.math.clamp(code, @as(c_int, -6), @as(c_int, 2));
    return std.mem.span(c.zError(clamped));
}

fn codeOrError(code: c_int) Error!void {
    const status = try statusOf(code);
    if (status.errorCode()) |err| return err;
}

/// The flush mode passed to `deflate` or `inflate`.
pub const Flush = enum(c_int) {
    no_flush = 0,
    partial_flush = 1,
    sync_flush = 2,
    full_flush = 3,
    finish = 4,
    block = 5,
    /// `Z_TREES 6` (`src/zlib.h:178`).
    trees = 6,
};

/// zlib compression levels; levels 2 through 8 are also accepted.
pub const Level = enum(c_int) {
    no_compression = 0,
    best_speed = 1,
    best_compression = 9,
    default_compression = -1,
    _,
};

/// The compression strategy passed to `deflate`.
pub const Strategy = enum(c_int) {
    /// Default compression strategy.
    default = 0,
    /// For data with a small alphabet.
    filtered = 1,
    /// Huffman coding without LZ77 matching.
    huffman_only = 2,
    /// Run-length encoding only.
    rle = 3,
    /// Uses the fixed Huffman codes from RFC 1951 §3.2.6.
    fixed = 4,
};

/// The container format selected by a stream.
/// `windowBits` selects raw deflate, zlib, or gzip framing.
pub const Format = enum {
    /// Bare deflate stream without a header or trailer.
    raw,
    /// RFC 1950 zlib wrapper.
    zlib,
    /// RFC 1952 gzip wrapper; `windowBits` uses 15 + 16.
    gzip,

    /// Returns the `windowBits` value for a 32K window.
    pub fn windowBits(self: Format) c_int {
        return switch (self) {
            .raw => -15,
            .zlib => 15,
            .gzip => 31,
        };
    }
};

/// Progress reported by one `deflate` or `inflate` call.
pub const Progress = struct {
    /// Input bytes consumed.
    consumed: usize,
    /// Output bytes produced.
    produced: usize,
    /// The returned status; `ok` and `stream_end` are not errors.
    status: Status,
};

/// Pending output bytes and bits, plus the compressor state in use.
pub const Pending = struct {
    /// Produced bytes not yet flushed.
    bytes: usize,
    /// Pending bits in the final byte, from 0 to 7.
    bits: u8,
    /// Bytes of compressor state in use.
    used: usize,
};

/// Options used to initialize a compressor or call `compress2`.
pub const CompressOptions = struct {
    /// Compression level; defaults to zlib's default.
    level: Level = .default_compression,
    /// Compression strategy.
    strategy: Strategy = .default,
    /// Window size from 8 to 15; defaults to 15.
    window_bits: u8 = 15,
    /// Internal buffer size up to `max_mem_level`; defaults to 8.
    mem_level: u8 = 8,
};

/// A non-null pointer for the zero-length source passed to zlib.
const no_source: [*c]const c.Bytef = @ptrCast("");

/// Compresses `source` into a zlib stream in `dest`; returns bytes written.
/// Returns `BufError` when `dest` is too small; `source` is not retained.
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

/// Compresses with zlib's default compression level.
pub fn compress(dest: []u8, source: []const u8) Error!usize {
    return compress2(dest, source, .{});
}

/// Decompresses one zlib stream into `dest`; returns the number of bytes written.
/// `BufError` means insufficient space; `DataError` may follow partial output.
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

/// Decompresses one zlib stream and advances `source` past the consumed bytes.
/// Returns output length; `BufError` does not report the required buffer size.
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

/// Returns an upper bound for compressing `source_len` bytes.
pub fn compressBound(source_len: usize) usize {
    const bound: c_ulong = c.compressBound(@intCast(source_len));
    return @intCast(bound);
}

/// Computes Adler-32 for `bytes`, continuing from `adler`.
/// Use `checksum.adler32_init` for a new checksum.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    const value: c_ulong = c.adler32(@intCast(adler), bytes.ptr, @intCast(bytes.len));
    return @truncate(value);
}

/// Combines checksums of adjacent runs; `len2` is the second run's byte length.
pub fn adler32_combine(adler1: u32, adler2: u32, len2: usize) u32 {
    const value: c_ulong = c.adler32_combine(
        @intCast(adler1),
        @intCast(adler2),
        @intCast(len2),
    );
    return @truncate(value);
}

/// Computes CRC-32 for `bytes`, continuing from `crc`.
/// Use `checksum.crc32_init` for a new checksum.
pub fn crc32(crc: u32, bytes: []const u8) u32 {
    const value: c_ulong = c.crc32(@intCast(crc), bytes.ptr, @intCast(bytes.len));
    return @truncate(value);
}

/// Combines CRC-32 values for adjacent runs; `len2` is the second run's byte length.
pub fn crc32_combine(crc1: u32, crc2: u32, len2: usize) u32 {
    const value: c_ulong = c.crc32_combine(@intCast(crc1), @intCast(crc2), @intCast(len2));
    return @truncate(value);
}

/// Precomputes the CRC-32 combine operator for a second run of `len2` bytes.
/// The operator for a zero-length run is nonzero.
pub fn crc32_combine_gen(len2: usize) u32 {
    const value: c_ulong = c.crc32_combine_gen(@intCast(len2));
    return @truncate(value);
}

/// Combines CRC-32 values with an operator from `crc32_combine_gen`.
pub fn crc32_combine_op(crc1: u32, crc2: u32, op: u32) u32 {
    const value: c_ulong = c.crc32_combine_op(@intCast(crc1), @intCast(crc2), @intCast(op));
    return @truncate(value);
}

/// Initial values for Adler-32 and CRC-32.
pub const checksum = struct {
    /// Initial Adler-32 value.
    pub const adler32_init: u32 = 1;

    /// Initial CRC-32 value.
    pub const crc32_init: u32 = 0;

    /// Computes Adler-32 for an empty slice.
    pub fn adler32Empty() u32 {
        return adler32(adler32_init, "");
    }

    /// Computes CRC-32 for an empty slice.
    pub fn crc32Empty() u32 {
        return crc32(crc32_init, "");
    }
};

/// An owning compressor. Initialize it in place and call `deinit` once.
/// Do not copy an initialized value.
pub const Deflater = struct {
    /// The C stream. Zero until `init` succeeds.
    stream: c.z_stream,
    /// Format selected by `init`.
    format: Format = .zlib,

    /// An uninitialized stream.
    pub const empty: Deflater = .{ .stream = std.mem.zeroes(c.z_stream) };

    /// Initializes a compressor in place for `format`.
    /// Returns `Error`; on failure, `self` remains empty.
    pub fn init(self: *Deflater, options: CompressOptions, format: Format) Error!void {
        self.* = .empty;
        errdefer self.* = .empty;
        const code = c.deflateInit2_(
            &self.stream,
            @intFromEnum(options.level),
            // `Z_DEFLATED` is an integer macro, not an enum tag.
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

    /// Ends the stream and clears it; repeated calls do nothing.
    /// Panics if zlib rejects the end operation.
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

    /// Returns the underlying `z_stream`.
    pub fn handle(self: *Deflater) *c.z_stream {
        return &self.stream;
    }

    /// Processes input once and reports consumed bytes, produced bytes, and status.
    /// Borrows both slices; returns `Error` for zlib failures.
    pub fn run(self: *Deflater, input: []const u8, output: []u8, flush: Flush) Error!Progress {
        // zlib does not write through `next_in`, though the translation is mutable.
        self.stream.next_in = if (input.len == 0) null else @constCast(input.ptr);
        self.stream.avail_in = @intCast(input.len);
        // Pass `output.ptr` for empty slices; zlib rejects a null `next_out`.
        self.stream.next_out = output.ptr;
        self.stream.avail_out = @intCast(output.len);

        const code = c.deflate(&self.stream, @intFromEnum(flush));
        const consumed = input.len - @as(usize, @intCast(self.stream.avail_in));
        const produced = output.len - @as(usize, @intCast(self.stream.avail_out));

        const status = try statusOf(code);
        if (status.errorCode()) |err| return err;
        return .{ .consumed = consumed, .produced = produced, .status = status };
    }

    /// Runs until stream end or no input/output progress is possible.
    /// Returns cumulative progress and status.
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

    /// Returns this stream's output bound for `source_len`.
    /// Returns `StreamError` if the stream is inconsistent.
    pub fn bound(self: *Deflater, source_len: usize) Error!usize {
        const value: c_ulong = c.deflateBound(&self.stream, @intCast(source_len));
        if (value == 0) return error.StreamError;
        return @intCast(value);
    }

    /// Resets stream state while retaining its configuration.
    pub fn reset(self: *Deflater) Error!void {
        try codeOrError(c.deflateReset(&self.stream));
    }

    /// Changes the level and strategy for subsequent compression.
    /// Returns `Error` if zlib cannot apply the change.
    pub fn params(self: *Deflater, level: Level, strategy: Strategy) Error!void {
        try codeOrError(c.deflateParams(
            &self.stream,
            @intFromEnum(level),
            @intFromEnum(strategy),
        ));
    }

    /// Returns pending output and compressor-state usage.
    pub fn pending(self: *Deflater) Error!Pending {
        var bytes: c_uint = 0;
        var bits: c_uint = 0;
        try codeOrError(c.deflatePending(&self.stream, &bytes, &bits));
        const used: c_ulong = c.deflateUsed(&self.stream);
        return .{
            .bytes = @intCast(bytes),
            // zlib documents a pending-bit count from 0 to 7.
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

    /// Copies stream state into an empty destination, which the caller must deinitialize.
    /// Returns `Error`; copying may use substantial memory.
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

/// An owning decompressor. Initialize it in place and call `deinit` once.
/// `format` selects the wrapper that `inflate` expects.
pub const Inflater = struct {
    /// The C stream. Zero until `init` succeeds.
    stream: c.z_stream,
    /// Format selected by `init`.
    format: Format = .zlib,

    /// A stream that owns nothing; see `Deflater.empty`.
    pub const empty: Inflater = .{ .stream = std.mem.zeroes(c.z_stream) };

    /// Initializes a decompressor in place for `format`.
    /// Returns `Error`; on failure, `self` remains empty.
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

    /// Ends the stream and clears it; repeated calls do nothing.
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

    /// Returns the underlying `z_stream`.
    pub fn handle(self: *Inflater) *c.z_stream {
        return &self.stream;
    }

    /// Processes input once and reports consumed bytes, produced bytes, and status.
    /// Borrows both slices; returns `Error` for zlib failures.
    pub fn run(self: *Inflater, input: []const u8, output: []u8, flush: Flush) Error!Progress {
        // zlib does not write through `next_in`, though the translation is mutable.
        self.stream.next_in = if (input.len == 0) null else @constCast(input.ptr);
        self.stream.avail_in = @intCast(input.len);
        // Pass `output.ptr` for empty slices; zlib rejects a null `next_out`.
        self.stream.next_out = output.ptr;
        self.stream.avail_out = @intCast(output.len);

        const code = c.inflate(&self.stream, @intFromEnum(flush));
        const consumed = input.len - @as(usize, @intCast(self.stream.avail_in));
        const produced = output.len - @as(usize, @intCast(self.stream.avail_out));

        const status = try statusOf(code);
        if (status.errorCode()) |err| return err;
        return .{ .consumed = consumed, .produced = produced, .status = status };
    }

    /// Runs until stream end or no input/output progress is possible.
    /// Returns cumulative progress; truncated input may return `BufError`.
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

    /// Input bytes consumed since the last reset.
    pub fn totalIn(self: *const Inflater) usize {
        return @intCast(self.stream.total_in);
    }

    /// Output bytes produced since the last reset (`src/zlib.h:95`).
    pub fn totalOut(self: *const Inflater) usize {
        return @intCast(self.stream.total_out);
    }

    /// Resets stream state while retaining its format.
    pub fn reset(self: *Inflater) Error!void {
        try codeOrError(c.inflateReset(&self.stream));
    }

    /// Discards input through the next full-flush point.
    /// Returns `DataError` if no such point is found.
    pub fn sync(self: *Inflater) Error!void {
        try codeOrError(c.inflateSync(&self.stream));
    }

    /// Reports the decoder's bit position and emitted-byte count.
    /// Null `bits_back` means outside a block or inside a stored block.
    pub fn mark(self: *const Inflater) Mark {
        // `packed` is a Zig keyword.
        const raw_long: c_long = c.inflateMark(&self.stream);
        if (raw_long == -65536) return .{ .bits_back = null, .bytes_out = null, .failed = true };
        // `inflateMark` packs both values into the low 32 bits on supported targets.
        const raw: u32 = @truncate(raw_long);
        const upper: i16 = @bitCast(@as(u16, @truncate(raw >> 16)));
        const lower: u16 = @truncate(raw);
        return .{
            .bits_back = upper,
            .bytes_out = lower,
            .failed = false,
        };
    }

    /// Registers the caller-owned header buffers before the first `inflate`.
    /// Returns `StreamError` for raw or zlib formats; read results from `current`.
    pub fn readHeader(self: *Inflater, buffers: *HeaderBuffer) Error!void {
        if (self.format != .gzip) return error.StreamError;
        // zlib writes the header fields into these caller-owned buffers.
        buffers.head = std.mem.zeroes(c.gz_header);
        buffers.head.extra = buffers.extra[0..].ptr;
        buffers.head.extra_max = @intCast(buffers.extra.len);
        buffers.head.name = buffers.name[0..].ptr;
        buffers.head.name_max = @intCast(buffers.name.len);
        buffers.head.comment = buffers.comment[0..].ptr;
        buffers.head.comm_max = @intCast(buffers.comment.len);
        try codeOrError(c.inflateGetHeader(&self.stream, &buffers.head));
    }

    /// Copies stream state into an empty destination, which the caller must deinitialize.
    /// Returns `Error`; copying may use substantial memory.
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

/// The decoder position reported by `inflateMark`.
pub const Mark = struct {
    /// Bits back from the current position, or null outside a block or in a stored block.
    bits_back: ?i32,
    /// Bytes emitted for the current code, or null for an inconsistent stream.
    bytes_out: ?u16,
    /// Whether `inflateMark` reported an inconsistent stream.
    failed: bool,
};

/// Gzip header fields read into a caller-owned `HeaderBuffer`.
/// Pointer fields borrow that buffer's storage.
pub const GzipHeader = struct {
    /// Whether the header marks the data as text.
    text: bool = false,
    /// Modification time; zero means unavailable.
    time: u32 = 0,
    /// Extra flags, including the compression level indicator.
    xflags: i32 = 0,
    /// Operating system code from the gzip header.
    os: i32 = 0,
    /// Extra field data, borrowed from `HeaderBuffer.extra`.
    extra: ?[*]u8 = null,
    /// Number of valid extra-field bytes.
    extra_len: u32 = 0,
    /// Extra-field buffer capacity.
    extra_max: u32 = 0,
    /// Original file name, borrowed from `HeaderBuffer.name`.
    name: ?[*]u8 = null,
    /// File-name buffer capacity.
    name_max: u32 = 0,
    /// File comment, borrowed from `HeaderBuffer.comment`.
    comment: ?[*]u8 = null,
    /// File-comment buffer capacity.
    comm_max: u32 = 0,
    /// Whether the header carried an FHCRC.
    hcrc: bool = false,
    /// Whether upstream finished reading the header.
    done: bool = false,

    /// Returns the NUL-terminated file name as a borrow, or null if absent or truncated.
    pub fn nameSlice(self: GzipHeader) ?[:0]const u8 {
        const raw = self.name orelse return null;
        if (self.name_max == 0) return null;
        const window = raw[0..@intCast(self.name_max)];
        const end = std.mem.indexOfScalar(u8, window, 0) orelse return null;
        return window[0..end :0];
    }

    /// Returns the NUL-terminated comment as a borrow, or null if absent or truncated.
    pub fn commentSlice(self: GzipHeader) ?[:0]const u8 {
        const raw = self.comment orelse return null;
        if (self.comm_max == 0) return null;
        const window = raw[0..@intCast(self.comm_max)];
        const end = std.mem.indexOfScalar(u8, window, 0) orelse return null;
        return window[0..end :0];
    }

    /// Returns the extra field as a borrow, or null when absent or out of bounds.
    pub fn extraSlice(self: GzipHeader) ?[]const u8 {
        const raw = self.extra orelse return null;
        if (self.extra_len > self.extra_max) return null;
        return raw[0..@intCast(self.extra_len)];
    }
};

/// Caller-owned storage for a gzip header and its optional fields.
/// Upstream writes into fixed-size buffers and may truncate longer fields.
pub const HeaderBuffer = struct {
    /// Header storage filled by `Inflater.readHeader`.
    head: c.gz_header = std.mem.zeroes(c.gz_header),
    /// Destination for FNAME.
    name: [256]u8 = undefined,
    /// Destination for FCOMMENT.
    comment: [256]u8 = undefined,
    /// Destination for FEXTRA.
    extra: [64]u8 = undefined,

    /// Returns the current header fields; `done` indicates whether parsing completed.
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

/// Owning wrapper for zlib's `gzFile` API; `deinit` closes the handle.
/// Its internal state and buffers use the provider's allocator.
pub const Gzip = struct {
    /// The C handle, null until open.
    handle_: ?*c.gzFile_s,

    /// An unopened handle.
    pub const empty: Gzip = .{ .handle_ = null };

    /// Opens a file for reading; non-gzip input is passed through unchanged.
    /// Returns `OpenFailed` if zlib cannot open the file or allocate its state.
    pub fn openRead(path: [:0]const u8) Error!Gzip {
        return Gzip.init(path, "rb");
    }

    /// Opens `path` for writing, creating or truncating the file.
    pub fn openWrite(path: [:0]const u8) Error!Gzip {
        return Gzip.init(path, "wb");
    }

    /// Opens `path` with the `gzopen` mode string; returns `OpenFailed` on failure.
    pub fn init(path: [:0]const u8, mode: [:0]const u8) Error!Gzip {
        // `handle` is also a method name on `Gzip`.
        const gz = c.gzopen(path.ptr, mode.ptr);
        return .{ .handle_ = gz orelse return error.OpenFailed };
    }

    /// Wraps a caller-owned file descriptor; `deinit` leaves the descriptor open.
    /// Returns `OpenFailed` if zlib cannot create the gzip handle.
    pub fn adopt(fd: c_int, mode: [:0]const u8) Error!Gzip {
        const gz = c.gzdopen(fd, mode.ptr);
        return .{ .handle_ = gz orelse return error.OpenFailed };
    }

    /// Closes the handle and clears it; close errors are ignored.
    /// Read `lastError` first if the close error matters.
    pub fn deinit(self: *Gzip) void {
        const gz = self.handle_ orelse return;
        self.handle_ = null;
        _ = c.gzclose(gz);
    }

    /// Returns the underlying `gzFile` handle.
    pub fn handle(self: *const Gzip) ?*c.gzFile_s {
        return self.handle_;
    }

    /// Reads up to `dst.len` uncompressed bytes; returns `EndOfInput` at EOF.
    /// Errors come from `gzerror`; truncated input may fail at close.
    pub fn read(self: *Gzip, dst: []u8) Error!usize {
        const gz = self.require();
        const got: c_int = c.gzread(gz, if (dst.len == 0) undefined else dst.ptr, @intCast(dst.len));
        if (got < 0) return self.reportedError(error.EndOfInput);
        if (got == 0) return error.EndOfInput;
        return @intCast(got);
    }

    /// Reads up to `dst.len` bytes; returns zero at end of input.
    /// Other read failures are reported from `gzerror`.
    pub fn readSome(self: *Gzip, dst: []u8) Error!usize {
        const gz = self.require();
        const got: c_int = c.gzread(gz, if (dst.len == 0) undefined else dst.ptr, @intCast(dst.len));
        if (got < 0) return self.reportedError(error.EndOfInput);
        return @intCast(got);
    }

    /// Writes bytes and returns the number written.
    /// Returns `NotWritable` when zlib writes nothing for a non-empty request.
    pub fn write(self: *Gzip, bytes: []const u8) Error!usize {
        const gz = self.require();
        const put: c_int = c.gzwrite(gz, if (bytes.len == 0) undefined else bytes.ptr, @intCast(bytes.len));
        if (put < 0) return self.reportedError(error.NotWritable);
        if (put == 0 and bytes.len != 0) return error.NotWritable;
        return @intCast(put);
    }

    /// Reads a NUL-terminated line into `dst`, or returns null at end of input.
    /// The returned slice borrows `dst`.
    pub fn gets(self: *Gzip, dst: []u8) Error!?[:0]const u8 {
        const gz = self.require();
        const raw = c.gzgets(gz, if (dst.len == 0) undefined else dst.ptr, @intCast(dst.len));
        const line = raw orelse return null;
        return std.mem.span(@as([*:0]u8, @ptrCast(line)));
    }

    /// Reads one byte, or returns null when `gzgetc_` returns a negative value.
    pub fn getByte(self: *Gzip) Error!?u8 {
        const gz = self.require();
        const value: c_int = c.gzgetc_(gz);
        if (value < 0) return null;
        return @intCast(value);
    }

    /// Pushes back the last byte read; otherwise returns `DataError`.
    pub fn ungetByte(self: *Gzip, byte: u8) Error!void {
        const gz = self.require();
        try codeOrError(c.gzungetc(@intCast(byte), gz));
    }

    /// Writes one byte; returns `Errno` on a file error.
    pub fn putByte(self: *Gzip, byte: u8) Error!void {
        const gz = self.require();
        const put: c_int = c.gzputc(gz, @intCast(byte));
        if (put < 0) return error.Errno;
    }

    /// Writes `text` followed by a newline.
    /// `text` must be NUL-terminated.
    pub fn puts(self: *Gzip, text: [:0]const u8) Error!void {
        const gz = self.require();
        const put: c_int = c.gzputs(gz, text.ptr);
        if (put < 0) return error.Errno;
    }

    /// Seeks to an uncompressed-byte position using `origin`.
    /// Returns `Errno` on a file error.
    pub fn seek(self: *Gzip, distance: i64, origin: SeekOrigin) Error!i64 {
        const gz = self.require();
        const at = c.gzseek(gz, @intCast(distance), @intFromEnum(origin));
        if (at == -1) return error.Errno;
        return @intCast(at);
    }

    /// Returns the current position in uncompressed bytes.
    pub fn tell(self: *Gzip) Error!i64 {
        const gz = self.require();
        const at = c.gztell(gz);
        if (at == -1) return error.Errno;
        return @intCast(at);
    }

    /// Returns the current position in the compressed file.
    pub fn offset(self: *Gzip) Error!u64 {
        const gz = self.require();
        const at = c.gzoffset(gz);
        if (at == -1) return error.Errno;
        return @intCast(at);
    }

    /// Returns to the start of the file.
    pub fn rewind(self: *Gzip) Error!void {
        const gz = self.require();
        try codeOrError(c.gzrewind(gz));
    }

    /// Reports whether the underlying file reached EOF; buffered output may remain.
    pub fn eof(self: *Gzip) bool {
        const gz = self.handle_ orelse return true;
        return c.gzeof(gz) != 0;
    }

    /// Reports whether input is being passed through without decompression.
    /// The result is meaningful after a read.
    pub fn direct(self: *Gzip) bool {
        const gz = self.handle_ orelse return true;
        return c.gzdirect(gz) != 0;
    }

    /// Sets the internal buffer size; call before reading or writing.
    /// Returns the size actually used, which may be rounded up.
    pub fn buffer(self: *Gzip, size: u32) Error!u32 {
        const gz = self.require();
        const got: c_int = c.gzbuffer(gz, size);
        if (got < 0) return error.MemError;
        return @intCast(got);
    }

    /// Returns the last error and its code, or null when none is recorded.
    /// The message borrows handle storage until the next `gz*` call or close.
    pub fn lastError(self: *Gzip) ?GzipError {
        const gz = self.handle_ orelse return null;
        var code: c_int = @intFromEnum(Status.ok);
        const raw = c.gzerror(gz, &code);
        const text = raw orelse return null;
        if (code == @intFromEnum(Status.ok)) return null;
        return .{ .message = std.mem.span(@as([*:0]const u8, @ptrCast(text))), .code = code };
    }

    /// Flushes buffered output using `mode`; returns `Error` on failure.
    pub fn flush(self: *Gzip, mode: Flush) Error!void {
        const gz = self.require();
        try codeOrError(c.gzflush(gz, @intFromEnum(mode)));
    }

    /// Changes compression parameters for later writes.
    /// Returns `Error` if zlib cannot apply the change.
    pub fn setParams(self: *Gzip, level: Level, strategy: Strategy) Error!void {
        const gz = self.require();
        try codeOrError(c.gzsetparams(gz, @intFromEnum(level), @intFromEnum(strategy)));
    }

    /// Returns the handle or panics if this value owns no open file.
    fn require(self: *Gzip) *c.gzFile_s {
        return self.handle_ orelse @panic(
            "zlib: this Gzip owns no file; it was never opened, or deinit already " ++
                "closed it. Open a new one.",
        );
    }

    /// Returns the error reported by `gzerror`, or `fallback` if none is recorded.
    fn reportedError(self: *Gzip, fallback: Error) Error {
        var code: c_int = @intFromEnum(Status.ok);
        const raw = c.gzerror(self.require(), &code);
        _ = raw;
        if (code == @intFromEnum(Status.ok)) return fallback;
        // Unknown or unrecorded status codes use the supplied fallback.
        const status = statusOf(code) catch return fallback;
        return status.errorCode() orelse fallback;
    }
};

/// Error details from `gz*`, including a message borrowed from the `Gzip` handle.
/// The message is valid until the next `gz*` call or close; copy it to retain it.
pub const GzipError = struct {
    /// Borrowed zlib error message.
    message: [:0]const u8,
    /// Numeric zlib status code.
    code: c_int,
};

/// The origin used by `Gzip.seek`.
pub const SeekOrigin = enum(c_int) {
    /// From the beginning of the file.
    set = 0,
    /// From the current position.
    current = 1,
    /// From the end of the file.
    end = 2,
};
