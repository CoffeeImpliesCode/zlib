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

Fetch zlib from GitHub and save its pinned URL and hash to the consumer's `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/CoffeeImpliesCode/zlib#v1.3.2
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

## Licence

Upstream zlib 1.3.2 is Copyright (C) 1995-2026 Jean-loup Gailly and Mark Adler. The upstream source is unmodified; this fork adds Zig packaging and bindings. See [NOTICE.md](NOTICE.md) and [FORK-LICENSE.md](FORK-LICENSE.md) for the file inventory and fork terms.

The upstream grant from `src/LICENSE` is reproduced here:

```text
Copyright notice:

 (C) 1995-2026 Jean-loup Gailly and Mark Adler

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.

  Jean-loup Gailly        Mark Adler
  jloup@gzip.org          madler@alumni.caltech.edu
```
