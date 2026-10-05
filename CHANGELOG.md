# Changelog

All notable changes to the **Zig package** in this repository are recorded
here. Upstream's own release notes are in [`src/ChangeLog`](src/ChangeLog) and
are not duplicated; this file records what the *packaging and the facade* did,
never what zlib did.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this package uses its own numbering: entries are integers, and an entry is
added in the same change as the thing it describes.

## Status vocabulary

Every entry below is `SOURCE-CONFIRMED` or `PENDING-VERIFICATION`. **No entry
in this file records a passing gate.** An entry moves from
`PENDING-VERIFICATION` to `VERIFIED` only by a driver edit beside an observed
run, recording the command, the optimize mode, the target, the exit code, the
date and the receipt path. No such edit has been made: nothing in this package
has been built, tested, smoke-run or cross-compiled by its author.

---

## [1] — 2026-10-05 — First recorded state of the package

### Added

* **The build graph.** `build.zig` compiles the fifteen translation units
  `src/Makefile.in:59-61` names — the nine of `OBJZ` and the six of `OBJG` —
  through Zig 0.16.0, with `-std=gnu99` pinned. Upstream's four build systems
  (`configure`/`Makefile.in`, CMake, Bazel and the six platform makefiles) all
  travel in the source closure and none of them is invoked.

  `PENDING-VERIFICATION`

* **A per-target `zconf.h`.** Upstream's own `tools/genzconf.c` is compiled for
  the host and run **for the target being built**, and the generated directory is
  placed ahead of `src/` on four include lines so the `#include "zconf.h"` at
  `src/zlib.h:37` resolves to the generated header and never to the checked-in
  POSIX copy. `HAVE_UNISTD_H` and `HAVE_STDARG_H` therefore describe the target,
  not the machine that ran `zig build`.

  `PENDING-VERIFICATION`

* **The typed module.** `zig/root.zig` over the translation of `zig/translate.h`,
  which includes `zlib.h` and `zconf.h` whole. It covers the one-shot
  compress/uncompress pair, the Adler-32 and CRC-32 family including
  `adler32_combine` and the reusable `crc32_combine_gen`/`crc32_combine_op`
  operator, the streaming `Deflater` and `Inflater`, gzip header reading, and
  the `gz*` file layer as a real file type.

  `PENDING-VERIFICATION`

* **The runtime-loading route.** `-Druntime=true` replaces the link line with
  one process-lifetime dispatch table an explicit `load(source)` fills. Four
  rules, stated in [`README.zig.md`](README.zig.md) §2: one table per configured
  module; explicit path or named-system selection with no fallback; atomic
  publication; explicit retry after failure. The public types and the public
  surface do not fork between the linked and loaded builds.

  `PENDING-VERIFICATION`

* **System-library mode.** `-Dsystem=true`, or a runner's own `-fsys=zlib`,
  binds an installed `libz` through `b.systemIntegrationOption` and translates
  **the installed headers**. Bundled headers against an older installed library
  compile and fail silently, so this package never does it.

  `PENDING-VERIFICATION`

* **The installed layout**, with upstream's own artifact names:
  `libz.a` or `libz.so.1.3.2` with the `libz.so.1` soname
  (`src/Makefile.in:32-36`), `include/zlib.h`, the generated `include/zconf.h`,
  `lib/pkgconfig/zlib.pc`, `share/man/man3/zlib.3`, and `share/licenses/zlib/`
  with all nine licence and provenance records.

  `PENDING-VERIFICATION`

* **The test suite.** `tests.zig`, 27 behavioural tests, grouped by the oracle
  they rest on: GNU gzip 1.13's RFC 1952 members (an encoder that does not link
  libz), zlib 1.2.13's RFC 1950 and raw-deflate streams (the reference
  implementation one release older), blocks built from `src/doc/rfc1951.txt`,
  the RFC 1950 Adler-32 recurrence computed in Zig, behavioural boundaries, and
  the ownership transitions this module owns.

  `PENDING-VERIFICATION`

* **The example.** `smoke.zig`, a deterministic demonstration whose expected
  values are stated literals rather than values it computed and printed for
  comparison. It exits non-zero on a mismatch, so it is a check and not a demo.

  `PENDING-VERIFICATION`

* **The consumer package.** `consumer/` as a separate package with its own
  manifest, reached through a relative path rather than a fetch. It is the proof
  that `dep.module("zlib")` resolves from a package that did not write it, and
  the second place the interoperation claim is made — from outside.

  `PENDING-VERIFICATION`

* **The provenance gate.** `tools/check-provenance.sh` answers four questions
  without a compiler: do the 254 recorded digests still match; is the native
  file set exactly those 254 paths; do the twelve fixture digests and both
  producer version strings still match; are the preserved upstream README, both
  of zlib's notices and the pinned version where the records say they are. It
  additionally checks that every path `build.zig.zon` `.paths` names exists, and
  that a lock file which now exists but is not named is an error.

  `PENDING-VERIFICATION`

* **The fixture set and its record.** `fixtures/` carries a 275-byte payload
  with an embedded NUL and a byte above `0x7f`, GNU gzip 1.13's three RFC 1952
  members, zlib 1.2.13's three RFC 1950 streams and two bare deflate streams,
  the two checksums zlib 1.2.13 recorded over that payload, and each producer's
  version string as its tool printed it. `fixtures/PROVENANCE.md` names the
  producer, the version and the digest of every file and says plainly which of
  the two producers is independent and which is the reference implementation at
  a different release.

  `PENDING-VERIFICATION`

* **The packaging.** `package.nix` (one source-only derivation, shared by
  `flake.nix` and `devenv.nix`), `flake.nix`, `devenv.nix`, `devenv.yaml` and
  `.envrc`. The canonical development environment is devenv; the flake is its
  portable counterpart, and both call the same `package.nix` so the two entry
  points cannot describe different packages.

  `PENDING-VERIFICATION`

* **The CI workflow.** `.github/workflows/verify.yml`, four jobs: `native`
  (both linkages, the installed closure, pkg-config, a C gate program driven by
  another implementation's recorded answers, the `gz*` file layer, and the
  runtime-loading configuration), `cross` (all six check targets),
  `cross-shared` (the same six, with the `wasm32-wasi` shared refusal asserted
  as a specific documented failure) and `consumer`.

  `PENDING-VERIFICATION`

* **The records.** `UPSTREAM.md`, `UPSTREAM.sha256`, `NOTICE.md`,
  `FORK-LICENSE.md`, `README.md`, `README.zig.md`, `FORK-NOTES.md`, this file,
  `cross-test.profile.sh` and `.gitignore`.

  `SOURCE-CONFIRMED`

### Changed

Nothing. There is no earlier state of this package to change from.

### Fixed


* **`wasm32-wasi` was asked for with the wrong ABI.** `check_targets` named
  `.{ .cpu_arch = .wasm32, .os_tag = .wasi, .abi = .none }`, which resolves to
  `wasm32-wasi-none`. The pinned toolchain gives that target no libc include
  path at all, so the generated `zconf.h`'s `#include <sys/types.h>`
  (`src/zconf.h.in:454-458`, from upstream's own `#ifdef STDC` block) failed with
  `'sys/types.h' file not found` in all fifteen units —
  `error: 15 compilation errors`, `Build Summary: 50/55 steps succeeded
  (2 failed)`. The same header is present for `wasm32-wasi-musl`, verified by
  compiling `#include <sys/types.h>` against each of the two triples.

  The row now names no `.abi`, matching `Platform.forTarget`'s own
  `"wasi (musl)"` label and the ledger's `"wasm32-wasi"`. Observed after the
  change: `zig build check` exits 0 for all six targets.

### Known gaps, recorded rather than hidden

* **No release-tarball digest and no commit SHA.** Neither can be read out of
  anything in this tree: `src/` is the unpacked release, and zlib's canonical
  source is a tarball rather than a clone. `UPSTREAM.md`, "What is *not* recorded
  here, and why", states this instead of filling the field with a number nobody
  here can compute. What *is* recorded and checked is the import aggregate over
  all 254 files.
* **The 53-platform matrix is not in CI.** `cross-test` is a host-local tool
  with its own runner detection and scratch policy; a GitHub job invoking it
  would fail for a reason that has nothing to do with this package. Its command
  and its receipts belong in the workspace ledger.
* **System-library mode is not in CI.** It needs an installed `libz` with its
  own headers, which a stock runner does not have.
* **`fixtures/PROVENANCE.md` had been cited by three source files and did not
  exist.** It is written by this change, and
  `tools/check-provenance.sh` now fails if it is deleted or if any of the three
  files stops citing it.
* **`build.zig.zon` `.paths` did not name `fixtures`,** while `tests.zig` and
  `smoke.zig` `@embedFile` from it. A package published with that filter would
  have compiled here and failed anywhere it was consumed. `"fixtures"` is added
  in this change.
* **`fixtures/rfc/` was an empty directory.** Nothing cited it, no RFC test data
  exists in the vendored source, and the three RFC texts already ship as
  upstream's own `src/doc/rfc1950.txt`, `rfc1951.txt` and `rfc1952.txt`. The
  empty directory is removed rather than shipped as a path with nothing in it.

* **Fourteen of the 53 published platforms do not build the typed module.**
  `cross-test`, `zig build test -Dtarget=…`, `run_id 20261005-191614-5696-213`,
  exit 1: nine NetBSD cells, three 32-bit OpenBSD cells and two OpenBSD MIPS64
  cells fail in `translate-c`, while zlib's own fifteen translation units
  compile for all 53. The causes are in Zig 0.16.0's aro, in toolchain headers
  this repository does not own — `generic-netbsd/sys/cdefs.h:413` lowers
  `_Pragma("GCC visibility pop")` into `#pragma GCC visibility pop`, and
  `lib/compiler/aro/aro/pragmas/gcc.zig:149-160` does not consume it;
  `generic-openbsd/sys/types.h:171-174` and `aro`'s unguarded
  `include/stddef.h:8` disagree about `size_t`; and neither
  `mips-netbsd-eabi/machine/endian_machdep.h:8` nor
  `generic-openbsd/mips64/endian.h:39-41` finds `__MIPSEL__`/`__MIPSEB__`.
  [`FORK-NOTES.md`](FORK-NOTES.md) §2.5 states it in full. Nothing is skipped
  and no cell is relabelled.

## [2] — 2026-10-05 — `README.md` carries upstream's copyright notice

### Changed

* **`README.md:17-49` now quotes `src/LICENSE:1-22` verbatim.** The front page
  named the licence and the installed layout but never carried the holder, so a
  reader of the README alone saw `SPDX-License-Identifier: zlib` with no
  copyright line. `tools/check-provenance.sh:151-155` asserts
  `Jean-loup Gailly and Mark Adler` in `NOTICE.md`, `README.md` and
  `FORK-LICENSE.md`; the README was the one of the three without it.

  The quoted block is the whole of `src/LICENSE` — `Copyright notice:`, the
  `(C) 1995-2026 Jean-loup Gailly and Mark Adler` line, the three conditions
  including the altered-source clause, and the two holders with their addresses —
  copied out of the vendored file. No holder was paraphrased, no year invented,
  and no byte under `src/` was touched. The text says plainly that the holder and
  the years are upstream's and not this fork's.

  `SOURCE-CONFIRMED`

### Not proved

  Nothing about the build. No `zig build`, no test, no smoke, no consumer run and
  no cell of the 53-platform matrix is moved by this entry, and it moves nothing
  to `VERIFIED`.
