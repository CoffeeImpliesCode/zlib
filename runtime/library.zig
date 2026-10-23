// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.
//
//! zlib 1.3.2 provider descriptor for this package's configured `zlib.h` and `zconf.h`.
//! Probes check version, reported flags, round-trip behavior, and `compressBound`, not every ABI detail.
//! `Z_PREFIX` fails symbol lookup; `ZLIB_CONST` has no runtime flag and is controlled at build time.
const std = @import("std");

const rt = @import("rt");

/// zlib's namespaced synchronization binding from `runtime/sync.c`.
/// The symbol prefix must match `runtime/graph.zig`; loader state remains per instance.
pub const Sync = struct {
    extern fn zlib_rt_lock() void;
    extern fn zlib_rt_unlock() void;
    extern fn zlib_rt_wait() void;
    extern fn zlib_rt_broadcast() void;
    // C's `unsigned long long`, represented as `u64` on supported targets.
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

/// Bytes of the embedded `src/zlib.h`, supplied through the build's `zlib_header` import.
/// The build provides a module-local copy because this package cannot embed outside its root.
const zlib_header = @import("zlib_header").bytes;

/// Parsed `ZLIB_VERSION` from the embedded header, if present.
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

/// Small round-trip input used to validate a provider.
const probe_input = "zlib runtime provider validation payload";

/// Length of the validation input.
const probe_input_len = probe_input.len;
/// Maximum accepted `compressBound` result for the validation probe.
const probe_output_max = 1024;

/// Returns the loader configuration for the generated dispatch.
/// The dispatch supplies its table type; this descriptor does not import it.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Name used in the pre-load panic.
        pub const library_name = "zlib";

        /// Required table and symbol metadata from the generated dispatch.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// Namespaced synchronization binding.
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

        /// Checks provider version, flags, round-trip behavior, and bounds.
        /// Returns a refusal reason; the loader closes the candidate before publication.
        pub fn validate(dst: *const table) ?[]const u8 {
            const expected = expected_version orelse return
                "the embedded src/zlib.h has no ZLIB_VERSION definition, so this " ++
                "loader cannot state what it expects a provider to report";

            // Require the provider version to start with the embedded header version.
            const reported = std.mem.span(dst.zlibVersion());
            if (!std.mem.startsWith(u8, reported, expected)) {
                // Print both versions without allocating diagnostic text.
                std.debug.print(
                    "zlib: provider reports zlibVersion \"{s}\", this SDK's " ++
                        "src/zlib.h:44 declares ZLIB_VERSION \"{s}\"; a 1.3.2 " ++
                        "consumer cannot use that provider's ABI\n",
                    .{ reported, expected },
                );
                return "this provider reports a zlib version that is not the " ++
                    "one this SDK's headers describe";
            }

            // Only debug and WINAPI configuration bits are observable here.
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

            // Exercise provider compression and decompression to catch basic ABI mismatches.
            // Check the caller-owned buffers and lengths after both calls.
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

            // A sentinel detects success without writing the expected payload.
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

            // Require `compressBound` to bound a known input size.
            // An undersized result could make callers overrun their output buffers.
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
