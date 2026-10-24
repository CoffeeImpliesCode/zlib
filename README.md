# zlib for Zig

This package builds upstream zlib 1.3.2 with Zig 0.17.0. It provides a typed Zig facade and the C library.

## Source deviations from upstream

No file under `src/` is modified. The build generates a target-specific `zconf.h` from `src/zconf.h.in` and uses it instead of the unconfigured `src/zconf.h`.

## Build deviations

`build.zig` replaces upstream's `configure`, Make, CMake, Bazel, and platform makefiles. It compiles the 15 root source files in upstream's `OBJZ` and `OBJG` lists. It does not build upstream's `example` or `minigzip` programs.

## Support matrix

When no target is named, `zig build check` compiles the selected bundled configuration for these targets. Shared linkage or runtime loading excludes targets without a dynamic loader. With `-Dtarget` or system mode, it checks only the selected target. The step compiles but does not run programs.

| Target | Static | Shared |
|---|:---:|:---:|
| `x86_64-linux-gnu` | yes | yes |
| `aarch64-linux-gnu` | yes | yes |
| `aarch64-macos-none` | yes | yes |
| `x86_64-windows-gnu` | yes | yes |
| `riscv64-linux-gnu` | yes | yes |
| `wasm32-wasi` | yes | no |

Shared linkage requires a target with a dynamic linker. The build refuses it when the target has none. On targets with a dynamic loader, `check` also runs `check-runtime`, which compiles runtime-loaded tests, smoke, and consumer without loading a provider.

## Consumption

Add zlib to the dependent package's `build.zig.zon`:

```zon
.dependencies = .{
    .zlib = .{ .path = "../zlib" },
},
```

Use the module in the dependent's `build.zig`:

```zig
const dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zlib", dep.module("zlib"));
```

The module and artifact names are both `zlib`. `dep.module("zlib")` is the typed facade and carries the library in linked mode. `dep.artifact("zlib")` is the C library. C consumers use the installed `zlib.h`, generated `zconf.h`, and pkg-config name `zlib` (`-lzlib`). See [README.zig.md](README.zig.md) for facade declarations.

| Option | Values | Default | Effect |
|---|---|---|---|
| `-Dlinkage` | `static`, `dynamic` | `static` bundled; `dynamic` system | Selects the delivered artifact or system library linkage. ELF shared delivery uses `libzlib.so.1.3.2` with soname `libzlib.so.1`. |
| `-Druntime` | `true`, `false` | `false` | Makes the facade resolve an explicitly loaded library at run time instead of linking it. |
| `-Dsystem` | `true`, `false` | `false` | Uses an installed `libzlib` and its headers instead of the bundled source. The build runner's `-fsys=zlib` setting overrides this default. |
| `-Dtarget` | Zig target triple | host | Selects the target. |
| `-Doptimize` | Zig optimization mode | Zig default | Selects the optimization mode. |

In bundled mode, static delivery produces `libzlib.a`. In runtime mode, the facade does not link an artifact; call `zlib.load` with the provider to use.

System mode requires this package's installed artifact and headers for the selected target. Supply its prefix with `--search-prefix <path>`; translation and linking search `<path>/include` and `<path>/lib`. The nested `consumer` build forwards all search prefixes. System linking bypasses host `zlib.pc`, which can select a different `libz`. Search-prefix forwarding disables configuration caching under Zig 0.17.
