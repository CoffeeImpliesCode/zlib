# Fork notes

## Source changes

The vendored `src/` tree is unmodified. The fork adds these implementation files:

| File | Change and reason |
|---|---|
| `tools/genzconf.c` | Replaces configure-time header rewriting with a target-parameterized generator for cross builds. |
| `zig/translate.h` | Wraps the public headers for `translate-c` so Zig sees the configured API and types. |
| `zig/root.zig` | Adds a typed Zig facade with stream, slice, error, and gzip-handle APIs over the C library. |
| `runtime/graph.zig` | Wires the translated declarations to a runtime-loaded dispatch instead of link-time calls. |
| `runtime/generate.zig` | Generates typed dispatch wrappers from `translate-c` output so signatures match the translated declarations. |
| `runtime/loader.zig` | Adds explicit provider loading and process-lifetime symbol-table publication for runtime linkage. |
| `runtime/library.zig` | Defines zlib's provider ABI checks so incompatible libraries are rejected. |
| `runtime/sync.h` | Declares namespaced synchronization functions so loader state does not collide across SDKs. |
| `runtime/sync.c` | Implements synchronization for Windows, WASI/Emscripten, and pthread-based targets. |

## Build graph

- `build.zig` is the package build graph; upstream configure, Make, CMake, and Bazel entry points are not invoked.
- The bundled build compiles upstream's 15 `OBJZ` and `OBJG` C translation units with `-std=gnu99`; it omits upstream's example and test executables.
- A host-built `genzconf` uses target properties to configure `zconf.h`; its output precedes `src/` in compile and translation include paths and is installed as the public header.
- Bundled mode defaults to `libz.a`; dynamic mode uses upstream's `libz.so.1.3.2` name and `libz.so.1` soname, with the upstream ELF version script and COFF export list.
- `-Dsystem` binds an installed `libz` and its headers. `-Dlinkage` selects static or dynamic linkage, while `-Druntime` independently selects generated runtime dispatch. Bundled mode defaults to static linkage; system mode defaults to dynamic.
- Gzip paths in tests, smoke, and consumer programs use Zig 0.17's `std.mem.printSentinel` with a zero sentinel in place of `std.fmt.bufPrintZ`.

## Platform boundaries

- Dynamic linkage is refused for targets without a dynamic linker; `wasm32-wasi` supports the static artifact only. Runtime loading also requires a platform dynamic loader.
- With Zig 0.16, `translate-c` fails on these BSD targets in the toolchain headers: NetBSD `aarch64`, `aarch64_be`, `arm`, `armeb`, `powerpc`, `x86`, and `x86_64` encounter an unsupported GCC visibility pragma; NetBSD `mips` and `mipsel` lack the MIPS endian macros; OpenBSD `arm`, `x86`, and `powerpc` encounter a conflicting `size_t` definition; OpenBSD `mips64` and `mips64el` lack the MIPS endian macros. These are facade-translation boundaries, not changes to zlib's C sources (observed with Zig 0.16; not rechecked on 0.17).
- Zig 0.17 does not expose parent cache, prefix, or libc-runtime CLI values to the nested consumer build; environment cache variables still propagate.
- Nested consumer builds install cross-target executables requiring external executors because the 0.17 configurer does not expose executor toggles to its run/install choice.
