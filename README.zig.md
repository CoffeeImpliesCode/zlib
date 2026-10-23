# Zig facade API

This reference covers the public declarations on the `zlib` module.

## Loading

`runtime_loaded` is a compile-time `bool`. When it is true, call `load` before any other zlib operation. A call before loading panics. In linked builds, `loadedSource()` returns `null` and `load` panics.

`LoadSource.path` names an absolute file path. `LoadSource.system` names a library for the platform loader. Neither source falls back to the other. `LoadError` includes `EmptySource`, `SourceTooLong`, `InvalidSource`, `UnsupportedTarget`, `OpenFailed`, `MissingSymbol`, `ValidationFailed`, `ProviderMismatch`, and `ReentrantLoad`.

A successful load keeps its provider until process exit. Repeating the same request succeeds without reloading. A different request returns `ProviderMismatch`. A failed request can be retried.

## Status and version

- `Status` names the C status codes. `Error` is the error set returned by facade functions: `NeedDict`, `Errno`, `StreamError`, `DataError`, `MemError`, `BufError`, `VersionError`, `UnknownStatus`, `OpenFailed`, `EndOfInput`, and `NotWritable`.
- `statusOf(code)` maps a C status to `Status`; unknown values return `error.UnknownStatus`. `zError(code)` returns zlib's NUL-terminated message without allocating.
- `version` and `version_num` describe the translated header. `zlibVersion()` reports the selected library. `zlibCompileFlags()` reports its configuration. `flag_debug` and `flag_winapi` name bits 8 and 10.
- `c` exposes declarations from the translated zlib headers that the facade does not wrap.

## One-shot compression

| Declaration | Purpose |
|---|---|
| `compress(dest, source) Error!usize` | Compress with the default level. |
| `compress2(dest, source, options) Error!usize` | Compress with `options.level`. |
| `uncompress(dest, source) Error!usize` | Decompress a zlib-wrapped stream. |
| `uncompress2(dest, source: *[]const u8) Error!usize` | Decompress one stream and advance `source` past the consumed bytes. |
| `compressBound(source_len) usize` | Return an upper bound for compressed output. |

`CompressOptions` contains `level`, `strategy`, `window_bits`, and `mem_level`. Its defaults are `.default_compression`, `.default`, `15`, and `8`. `Deflater.init` uses all four fields; `compress2` uses `level`.

## Checksums

`adler32` and `crc32` continue a checksum from the supplied value. Their initial values are `checksum.adler32_init` (`1`) and `checksum.crc32_init` (`0`). The facade also exposes `adler32_combine`, `crc32_combine`, `crc32_combine_gen`, and `crc32_combine_op`. `checksum.adler32Empty()` and `checksum.crc32Empty()` return the empty-input values.

## Streaming

`Format` is `.raw`, `.zlib`, or `.gzip`. `Flush` names zlib's flush modes. `Progress` reports `consumed`, `produced`, and `status`; `Pending` reports pending `bytes`, `bits`, and `used` output state.

Initialize stream values in place, then call `deinit`:

```zig
var def: zlib.Deflater = .empty;
try def.init(.{}, .zlib);
defer def.deinit();
const progress = try def.runAll(input, output);
```

| Type | API |
|---|---|
| `Deflater` | `init`, `deinit`, `container`, `handle`, `run`, `runAll`, `bound`, `reset`, `params`, `pending`, `totalIn`, `totalOut`, `copyTo` |
| `Inflater` | `init`, `deinit`, `container`, `handle`, `run`, `runAll`, `reset`, `sync`, `mark`, `readHeader`, `totalIn`, `totalOut`, `copyFrom` |

`init` is fallible and initializes the value in place. `run` performs one step; `runAll` stops at stream end or when no progress is possible. Check `Progress.status` for stream end. Call `deinit` to release each initialized stream.

`HeaderBuffer` owns storage for a gzip header's name (256 bytes), comment (256 bytes), and extra field (64 bytes). Pass it to `Inflater.readHeader` before decoding, then read the result with `current()`. `readHeader` returns `error.StreamError` unless the inflater uses `.gzip`. `GzipHeader` provides `nameSlice`, `commentSlice`, and `extraSlice`; each slice borrows from its `HeaderBuffer`.

`Mark` contains `bits_back`, `bytes_out`, and `failed`, as reported by `Inflater.mark`.

## Gzip file layer

`Gzip.openRead` and `Gzip.openWrite` open paths. `Gzip.init` accepts a zlib mode string. `Gzip.adopt(fd, mode)` wraps a caller-owned descriptor; `deinit` does not close that descriptor. Call `deinit` to close the gzip handle.

| Methods | Purpose |
|---|---|
| `read`, `readSome`, `write` | Read or write byte slices. `read` reports EOF as `error.EndOfInput`; `readSome` returns zero at EOF. |
| `gets`, `getByte`, `ungetByte`, `putByte`, `puts` | Read or write lines, bytes, or NUL-terminated text. |
| `seek`, `tell`, `offset`, `rewind` | Change or query file positions. `tell` counts uncompressed bytes; `offset` counts compressed bytes. |
| `eof`, `direct`, `buffer`, `lastError`, `flush`, `setParams`, `handle` | Query or configure the gzip handle. |

`lastError()` returns a `GzipError`. Its message borrows the handle's storage and remains valid only until the next gzip call or close. `SeekOrigin` is `.set`, `.current`, or `.end`.