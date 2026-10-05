<!--
SPDX-License-Identifier: zlib
See FORK-LICENSE.md for what that identifier covers.
-->

# The `zlib` Zig module

The typed surface over zlib 1.3.2. `dep.module("zlib")` is this module;
`dep.artifact("zlib")` is the C library it talks to.

It is a **facade, not a binding generator**. Every public type here is a Zig
shape over a real C declaration in `zig/translate.h`; nothing is invented,
nothing is copied out of a header at comptime and re-derived, and no sentinel
is reconstructed. Where a value crosses the boundary and upstream does not own
its lifetime, this module owns it and says so.

`STATUS`: `SOURCE-CONFIRMED` throughout. Nothing in this file was executed.

---

## 1. Getting the module

```zig
const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("zlib", zlib_dep.module("zlib"));
exe.linkLibrary(zlib_dep.artifact("zlib"));
```

```zig
const zlib = @import("zlib");
```

## 2. The three modes, and what compiles in each

| Build | The module | Reaching the library |
|---|---|---|
| default | `@import("zlib")` | a link line against `libz.a` or `libz.so` |
| `-Dlinkage=dynamic` | identical | a link line against the shared object |
| `-Druntime=true` | identical API and identical types | `zlib.load(.{ .path = … })` fills one process-lifetime table |

`zlib.runtime_loaded` is a `comptime bool`, so a caller can write

```zig
if (comptime zlib.runtime_loaded) {
    try zlib.load(.{ .path = provider_path });
}
```

and it disappears entirely in a linked build. The API surface does not fork:
the same `compress2`, the same `Inflater`, the same `Error` set, whichever mode
the module was built in.

### Runtime loading: the four rules

1. **One process-lifetime table per configured module.** `load` is idempotent
   for the same request and keeps the handle to the end of the process.
2. **Explicit source, no fallback.** `load(.{ .path = p })` or
   `load(.{ .system = name })`. Nothing looks in a default location, and a
   runtime-loading build that was not told which file to load says so and
   stops — it does not fall back to a linked copy, because there is no linked
   copy to fall back to.
3. **Atomic publication.** The table is fully populated before any entry point
   becomes callable; a load that fails leaves the previous state untouched.
4. **Explicit retry after failure.** A failed `load` can be retried with a
   different source. The same source twice is not a second load.

A failed load in a build where no provider was configured **panics in every
optimization mode**, including `ReleaseFast` — that is a programming error, not
a runtime condition to be optimized away.

---

## 3. Errors and status

zlib reports failure through integer return codes, with `Z_OK` being `0`.

```zig
pub const Status = enum(c_int) { ok, stream_end, need_dict, errno, stream_error, /* … */ };
pub const Error  = error{ BufError, DataError, /* … */ };
```

* `statusOf(code)` maps a raw `c_int` to `Status`, or to the matching `Error`
  on a failure code. It is the one place that mapping lives.
* `zError(code)` is upstream's own `zError`: a `[:0]const u8` message, one per
  code the header defines. It is **not** an error union and never allocates.
* The error set is cut at what this package's own code checked. It is not a
  transcription of every name in `zlib.h`, and adding a name to it without a
  path that produces it would be a claim nothing backs.

```zig
const written = zlib.compress2(&out, payload, .{}) catch |err| switch (err) {
    error.BufError => return error.NoRoom,   // compressBound() says how much
    else => return err,
};
```

---

## 4. The one-shot surface

| Function | Upstream |
|---|---|
| `compress2(dest, source, options) Error!usize` | `compress2` |
| `compress(dest, source) Error!usize` | `compress` |
| `uncompress(dest, source) Error!usize` | `uncompress` |
| `uncompress2(dest, source: *[]const u8) Error!usize` | `uncompress2` |
| `compressBound(source_len) usize` | `compressBound` |
| `adler32(adler, bytes) u32` | `adler32` |
| `adler32_combine(a1, a2, len2) u32` | `adler32_combine` |
| `crc32(crc, bytes) u32` | `crc32` |
| `crc32_combine(c1, c2, len2) u32` | `crc32_combine` |
| `crc32_combine_gen(len2) u32` | `crc32_combine_gen` |
| `crc32_combine_op(c1, c2, op) u32` | `crc32_combine_op` |

### `uncompress2` takes a pointer, and that is deliberate

```zig
pub fn uncompress2(dest: []u8, source: *[]const u8) Error!usize
```

Upstream's `uncompress2` advances the caller's source pointer past the member it
decoded (`src/zlib.h:1335-1336`). A Zig `[]const u8` is immutable, so the
module takes a **pointer to the slice** and writes the remainder back through
it. That is the honest signature for an in-out pointer, not a wrapper that
quietly discards the second half of the return value.

```zig
var rest = frame;
const n = try zlib.uncompress2(&out, &rest);
// rest is now whatever followed the first member — frame N+1 and later.
```

A slice is used rather than a pointer-plus-length pair so that the length can
never disagree with the pointer.

### `compressBound` is an upper bound, not a promise

`compressBound(n)` is what `src/zlib.h:1307-1312` says it is: an upper bound on
the compressed size after compressing `n` bytes. It is a bound, not an answer —
the actual output is usually far smaller, and a caller that sizes a buffer to
it and then expects the buffer to be full has misread the contract.
`smoke.zig` asserts both halves: `compressBound(n) >= n`, and that a short
destination really does report `error.BufError` and leave the destination
untouched.

---

## 5. Checksums

```zig
pub const checksum = struct {
    pub const adler32_init: u32 = 1;   // src/doc/rfc1950.txt:327, "s1 is initialized to 1"
    pub const crc32_init: u32 = 0;      // the CRC-32 of no bytes
    pub fn adler32Empty() u32;
    pub fn crc32Empty() u32;
};
```

The two starting values are **not** re-derived: they are constants upstream
defines, and a facade that computed them from its own code could disagree with
upstream and there would be no way to tell which was right. They are stated, and
`smoke.zig` checks them against the RFC.

`adler32_combine` and `crc32_combine` are exposed both as the plain form and in
the precomputed-operator form (`crc32_combine_gen` / `crc32_combine_op`), because
the operator is reusable across many blocks and recomputing it per block is the
mistake those two functions exist to prevent.

---

## 6. Streaming: `Deflater` and `Inflater`

```zig
var def = try zlib.Deflater.init(.{ .level = .default }, .zlib);
const step = try def.runAll(payload, &out);
try testing.expectEqual(payload.len, def.totalIn());
def.deinit();
```

* `Deflater.init(options, format)` and `Inflater.init(format)` are fallible
  because upstream's are (`deflateInit2` / `inflateInit2` return `Z_STREAM_ERROR`
  for an impossible configuration).
* `runAll(input, output)` returns `Progress` or `Pending`, the two shapes the
  streaming API actually has.
* `totalIn` / `totalOut` are the stream's own running totals
  (`src/zlib.h:93` and `:95`), read from the stream rather than accumulated here.
* `bound(n)` is `deflateBound` for this stream's *current* configuration, which
  is why it is a method and not a free function: the answer changes when
  `deflateParams` changes the level.
* `reset()` reuses a stream's configuration (`src/zlib.h:986`, `inflateReset`);
  `deinit()` is idempotent, so a `defer` and an explicit end are both safe.

### Formats

```zig
pub const Format = enum { zlib, raw, gzip, auto };
```

`raw` is a bare deflate stream — a negative `windowBits`, per
`src/zlib.h:236-241`. `auto` lets the decoder read the wrapper out of the stream.

### gzip headers

```zig
var buffers: zlib.HeaderBuffer = .{};
var inf = try zlib.Inflater.init(.gzip);
defer inf.deinit();
const header = try inf.readHeader(&buffers);
```

`readHeader` needs storage for the variable-length fields, so it takes a
`HeaderBuffer` by value rather than allocating. The caller owns it, it has an
explicit `= .{}` default so `.{ .{} }` and a partial literal are both valid, and
nothing is left dangling: the buffer's lifetime is the caller's and the strings
point into it.

`readHeader` **fails on a stream with no gzip header**, and says so. It is not a
"give me zero fields" call.

---

## 7. The `gz*` file layer

```zig
{
    var f = try zlib.Gzip.openWrite(path);
    defer f.deinit();
    try f.write(payload);
    try f.flush(.sync_flush);
}
{
    var f = try zlib.Gzip.openRead(path);
    defer f.deinit();
    const n = try f.readSome(&buf);
    const at = try f.tell();
}
```

A real file type over `gzopen` / `gzread` / `gzwrite` / `gzclose`, so the path
errors are `error.FileNotFound` rather than a bare `Z_STREAM_ERROR`. `tell`,
`offset`, `direct`, `eof` and `flush` are `gztell`, `gzoffset`, `gzdirect`,
`gzeof` and `gzflush`.

`Gzip.openWrite` and `Gzip.openRead` are the only two constructors. There is no
"open either way" convenience that swallows a mode mistake, because a mode
mistake here is silent — the first write to a read handle and the first read from
a write handle both succeed and produce nothing.

---

## 8. Version and flags

```zig
zlib.version      // [:0]const u8, read out of ZLIB_VERSION in the header
zlib.version_num  // u32,          read out of ZLIB_VERNUM in the header
zlib.zlibVersion()   // what the *library* reports, not what the header declares
zlib.zlibCompileFlags() // u32
```

**`version` and `zlibVersion()` are different facts and this module keeps them
apart.** `version` comes from the translated header, so it describes what this
package was compiled against. `zlibVersion()` calls the provider, so in a
runtime-loading build it describes *the file that was loaded*. A build that
compared them would be asserting the provider is the one it was built against —
true by default, and exactly the thing that breaks when someone names a
different `.so`.

`flag_debug` (`1 << 8`) and `flag_winapi` (`1 << 10`) are the two configuration
bits this SDK refuses (`src/zlib.h:1226` and `:1228`); `smoke.zig` checks both
are clear, because a provider built with either would not be interchangeable
with one that is not.

---

## 9. The escape hatch

```zig
pub const c = @import("c");
```

Every declaration reachable from `zig/translate.h` is reachable through `c`.
That file includes `zlib.h` and `zconf.h` whole, so the translation is
whatever those two upstream headers declare, unmodified. That is deliberate:
the facade is a *convenience* layer, and a declaration it does not
wrap must still be callable without forking the package. `smoke.zig` uses it
for `zError` over every code the header defines, which is the case a facade
would otherwise have to grow a method for.

Use it when there is no wrapper. Prefer the wrapper when there is one: it is the
one that owns the error mapping and the slice lifetime.

---

## 10. What the tests are, and what they are not

`tests.zig` holds 27 behavioural tests. Grouped by what they rest on:

| Group | Oracle |
|---|---|
| RFC 1952 | `fixtures/gzip/*.bin`, produced by **GNU gzip 1.13** — an encoder that does not link libz, so it cannot have come from this library |
| RFC 1950 | `fixtures/pyzlib/zlib-n*.z`, produced by **zlib 1.2.13** — the reference implementation one release older |
| raw deflate | `fixtures/pyzlib/raw-n*.bin`, also zlib 1.2.13, bare streams with no wrapper |
| specification | blocks built from `src/doc/rfc1951.txt` §3.2.4 and §3.2.6, decoded against the literals the RFC gives |
| checksums | `fixtures/pyzlib/checksums.txt` — zlib 1.2.13's own two integers — **and** the RFC 1950 recurrence computed in Zig, agreeing three ways |
| boundaries | `BufError` on a short destination and on a truncated stream, `DataError` on a corrupt one and on a stream with no header, and that the stream is still usable after `inflateReset` |
| ownership | `deinit` is idempotent; one stream's `deinit` does not disturb another |

**No test here pins a version string, asserts that a decl exists, compares a
forwarder with its parts, or checks that a round trip returns non-zero.** Those
belong in the provenance and licence gates, and the version is available to
print in `smoke.zig` without being an assertion.

Round trips appear throughout. They **supplement** the oracles; no test exists
only to show that what this SDK compressed can be decompressed again. The full
producer record for every fixture, with digests, is
[`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md).

### The allocator

zlib allocates through libc, and this module does not route it through
`std.testing.allocator`. So `testing.allocator` cannot be a leak oracle for
anything zlib allocates, and no test claims it is. What a test can check is the
ownership transition this module owns: that `deinit` releases the stream, that
a second `deinit` is not a second free, and that two streams are independent.
Every buffer a test allocates itself is still freed, so the suite leaks nothing
of its own.