<!--
SPDX-License-Identifier: zlib
See FORK-LICENSE.md for what that identifier covers.
-->

# Notice

Two separate things are recorded here: what the canonical native source is and
which grant covers each of its files, and what this fork wrote on top of it.
[`FORK-LICENSE.md`](FORK-LICENSE.md) carries the grant for the second group.

## The upstream term

zlib is licensed under the **zlib licence**, a permissive, three-condition
grant. The authoritative copy in this tree is a standalone file,
`src/LICENSE`, and the same text appears a second time as the header block of
the public header at `src/zlib.h:1-29`. Both are present, both are digested,
and both are installed.

**Copyright (C) 1995-2026 Jean-loup Gailly and Mark Adler.**

The grant, verbatim from `src/LICENSE`:

> This software is provided 'as-is', without any express or implied warranty.
> In no event will the authors be held liable for any damages arising from the
> use of this software.
>
> Permission is granted to anyone to use this software for any purpose,
> including commercial applications, and to alter it and redistribute it freely,
> subject to the following restrictions:
>
> 1. The origin of this software must not be misrepresented; you must not claim
>    that you wrote the original software. If you use this software in a
>    product, an acknowledgment in the product documentation would be
>    appreciated but is not required.
> 2. Altered source versions must be plainly marked as such, and must not be
>    misrepresented as being the original software.
> 3. This notice may not be removed or altered from any source distribution.

### The three conditions, and what this repository does about each

This grant is not one of the licences where a scan-and-ship is enough, so each
condition is answered concretely rather than paraphrased:

1. **Origin must not be misrepresented.** Every delivered artefact is labelled
   as containing Gailly and Adler's zlib. `build.zig`'s `licence_records`
   installs `src/LICENSE` and `src/zlib.h` under `share/licenses/zlib/`, and
   the installed tree carries the notice. This package never presents its own
   work as zlib, and no fork-authored file claims an upstream copyright — see
   "Fork-specific notice" below.
2. **Altered sources must be plainly marked.** **No file under `src/` has been
   altered.** `UPSTREAM.sha256` plus the exact-file-set check in
   `tools/check-provenance.sh` are what make that checkable rather than
   asserted, and `tools/check-provenance.sh` additionally greps for the text of
   condition 2 in both `src/LICENSE` and `src/zlib.h` — so if the clause itself
   ever disappeared from the imported source, the provenance gate would say so
   rather than pass over it. A future native change has to mark the file, record
   the deviation in this inventory, move the digest, and add a numbered
   `CHANGELOG.md` entry, all in one change.
3. **The notice may not be removed or altered from any source distribution.**
   The notice is in the two upstream files above, in every record in this
   repository that names an upstream copyright, and in the installed tree.

## Inventory of the upstream files

254 files, every one digested in [`UPSTREAM.sha256`](UPSTREAM.sha256) and
included in the import aggregate recorded in [`UPSTREAM.md`](UPSTREAM.md).

The rows that say "covered by the blanket statement below" are covered by
zlib's own disclaimer, quoted immediately after the table. The counts are the
whole of `src/`, and they add up to 254.

| Path | Count | Term | Notice in the file |
|---|---:|---|---|
| `src/LICENSE` | 1 | **zlib, Gailly and Adler** | the full grant |
| `src/zlib.h` | 1 | **zlib, Gailly and Adler** | the full grant, `src/zlib.h:1-29` |
| `src/*.c` and `src/*.h`, except the four named above and below | 22 | **zlib, Gailly and Adler** | `Copyright (C) 1995-2026 Jean-loup Gailly and Mark Adler` |
| `src/crc32.h`, `src/inffixed.h`, `src/trees.h` | 3 | **zlib, Gailly and Adler** | **none in the file** — covered by the tarball's blanket statement below |
| `src/doc/` (6), `src/test/` (9), `src/examples/` (13), `src/win32/` (8), `src/os400/` (5), `src/msdos/` (5), `src/amiga/` (2), `src/watcom/` (2), `src/qnx/` (1) | 51 | **zlib, Gailly and Adler** | mostly none in the file — covered by the blanket statement |
| `src/Makefile`, `Makefile.in`, `configure`, `CMakeLists.txt`, `BUILD.bazel`, `MODULE.bazel`, `treebuild.xml`, `zconf.h.in`, `zlib.map`, `zlib.pc.in`, `zlib.pc.cmakein`, `zlibConfig.cmake.in`, `make_vms.com`, `.cmake-format.yaml` | 14 | **zlib, Gailly and Adler** | none in the file — covered by the blanket statement |
| `src/ChangeLog`, `FAQ`, `INDEX`, `README`, `README-cmake.md`, `zlib.3`, `zlib.3.pdf` | 7 | **zlib, Gailly and Adler** | none in the file — covered by the blanket statement |
| `src/contrib/` | **155** | **mixed — see "Per-file exceptions"** | upstream's own attribution index is `src/contrib/README.contrib` |

> All files under this contrib directory are UNSUPPORTED. They were provided by
> users of zlib and were not tested by the authors of zlib. Use at your own
> risk. Please contact the authors of the contributions for help about these,
> not the zlib authors.

The same disclaimer, applied to the whole tarball, is what upstream's release
process rests on: the tarball is one archive published by Gailly and Adler,
and a file inside it that carries no separate header is under the grant of the
archive.

`README.upstream.md` is a fork-side copy of `src/README`, kept under this
repository's naming convention and byte-identical to it. It is deliberately
**not** a 255th digested file: `UPSTREAM.sha256` records `src/README` alone,
and `tools/check-provenance.sh` is what proves the copy has not drifted.

**One duplication worth naming rather than glossing:** `src/zconf.h` and
`src/zconf.h.in` have the **same digest** in `UPSTREAM.sha256`
(`cb7c2c84211473b4699223edd363d3207b43b9578e739b5bf638f42204ea6e0f` for both).
They are byte-identical in this release — upstream ships a `zconf.h` that is
already configured for a POSIX host alongside the template. This package does
not use the checked-in `src/zconf.h`; it regenerates one for the target being
built from `tools/genzconf.c`. See `UPSTREAM.md`, "What is generated rather than
taken".

## Per-file exceptions

**`src/contrib/` is not zlib's licence, and one label cannot cover it.** All
155 files are retained and digested and **none of them is compiled** by
`build.zig` — the tree carries upstream's contributed material because it is
part of upstream's release, not because this package builds it. The terms inside
it vary, and upstream's own attribution index is
`src/contrib/README.contrib`, which names a contributor per subdirectory.

The two directories that carry a licence file of their own:

| Path | Term | Notice in the tree |
|---|---|---|
| `src/contrib/minizip/` (35 files) | **Info-ZIP licence**, version 2009-Jan-02 | `src/contrib/minizip/LICENSE.Info-Zip:1-6` — "Copyright (c) 1990-2009 Info-ZIP. All rights reserved." The list of named contributors at `:8-17` includes **Jean-loup Gailly and Mark Adler** among the Info-ZIP authors, so zlib's own authorship of parts of this directory is not in dispute |
| `src/contrib/dotzlib/` (15 files) | **Boost Software License 1.0**, 2003-08-17 | `src/contrib/dotzlib/LICENSE_1_0.txt:1` — "Boost Software License - Version 1.0 - August 17th, 2003". The directory is a .NET wrapper for `ZLib1.dll`, described in `src/contrib/dotzlib/readme.txt` |

The remaining thirteen `contrib/` subdirectories — `ada/` (22 files), `blast/`
(16), `crc32vx/` (4), `delphi/` (4), `gcc_gvmat64/` (2), `infback9/` (8),
`iostream/` (3), `iostream2/` (2), `iostream3/` (13), `nuget/` (2),
`pascal/` (4), `puff/` (17), `testzlib/` (3), `vstudio/` (1), `zlib1-dll/` (2)
— carry **no licence file of their own**. Several carry an inline copyright
notice naming their own author: `src/contrib/blast/blast.c` is by Mark Adler,
`src/contrib/iostream2/zstream.h` and `src/contrib/infback9/*` and
`src/contrib/minizip/crypt.h` and the rest of `minizip/` carry inline notices,
`src/contrib/puff/puff.c` and `puff.h` carry theirs, and `src/contrib/gcc_
gvmat64/gvmat64.S` carries one. `src/contrib/README.contrib` names the author
of each subdirectory in prose, and `src/contrib/README.contrib:1-5` is the
upstream statement that this material is contributed, unsupported and used at
the reader's own risk.

**The practical rule for a consumer of this package:** nothing under
`src/contrib/` is compiled into `libz.a`, `libz.so.1.3.2` or any other artefact
this package builds, so the zlib grant is the only one that reaches a shipped
binary. A consumer who deliberately builds something out of `src/contrib/` —
the `puff` decompressor, the `blast` decompressor, `minizip` — owes that
material's own terms, and this inventory is the record of which they are.

**There is no further carve-out elsewhere in the tree.** zlib's grant has no
dual-licensing clause, no public-domain dedication, no copyleft component and
no LGPL or GPL component. The `inflateBack` large-window support, the
`inflate9`/`infback9` variant, the `crc32_vx` vectorised CRC and the
`gvmat64` assembly are all upstream work under the same grant. The only
per-file exceptions in this package are the two directories above.

## What this fork changed in upstream files

**Nothing.** No file under `src/` has been edited, re-entered or reformatted,
and `src/README` is byte-identical to the tarball's copy of itself in
`README.upstream.md`.

That includes `src/zconf.h`: it ships in the tarball and this package does not
touch it. The header this build compiles against is generated into the build
cache for the target being built, and the generated directory is placed ahead
of `src/` on the include line, so upstream's checked-in copy is present,
digested, and unused. This is stated here because "the fork does not modify
upstream" and "the fork generates a header upstream also ships" read as
contradictory until the include-order detail is given.

`UPSTREAM.sha256` plus the exact-file-set check in `tools/check-provenance.sh`
are what make the claim checkable rather than asserted, and any future native
edit has to move those digests in the same change, with a numbered entry in
[`CHANGELOG.md`](CHANGELOG.md).

**`STATUS`: `SOURCE-CONFIRMED`** from the recorded digests — a claim about
bytes and about what this file asserts about them, not about a build. No build
result is recorded here. [`README.md`](README.md) carries the observed runs,
each row naming what was run and what came out, and marks every gate it does
not cover `PENDING-VERIFICATION`. Those are that file's observations; this
inventory does not restate or extend them.

## Fork-specific notice

Every file below was written for this fork. None of it carries an upstream
copyright, no upstream permission is claimed over it, and it is released under
the **zlib** terms recorded in [`FORK-LICENSE.md`](FORK-LICENSE.md) — the same
term as the primary upstream grant of this project, chosen under the owner's
per-project licence authorization:

* `build.zig`, `build.zig.zon`, `.gitignore`, `cross-test.profile.sh`,
  `.github/workflows/verify.yml`
* `zig/root.zig`, the typed facade, and `zig/translate.h`, the aggregate
  translation header this build runs `translate-c` over
* `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`,
  `consumer/src/main.zig`
* `runtime/` — the load-at-runtime route, as the six files it holds today.
  `loader.zig` is the reusable state machine and platform layer, holding no
  per-SDK name; `library.zig` is this SDK's descriptor, the namespaced
  synchronization binding and the one load-time check; `graph.zig` is the
  build half that wires them together and substitutes `createModule` for the
  translation's own; `generate.zig` is the build-time generator that writes the
  dispatch from the real translation output for the target being built, through
  `Run.addOutputFileArg`, so the generated file lands in the build cache and
  this directory holds no generated source. `sync.h` and `sync.c` are the two C
  files that give the loader its process-global mutex, condition variable and
  thread identity under an `RT_SYNC_PREFIX` this SDK sets; `sync.c` is compiled
  into the dispatch and `sync.h` is the only header the route compiles C
  against. All six are fork work under this grant; none of them is upstream
  material, and `sync.c` is not a substitute for any upstream unit.
* `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`
* `tools/check-provenance.sh`, alongside `tools/genzconf.c`, which is **not**
  fork work: `genzconf.c` is upstream's own generator, shipped in the tarball,
  and is covered by the zlib grant above.
* `fixtures/` — the interoperation fixture set and its provenance record.
  Every byte under `fixtures/` was **produced by another program**, not
  authored here; [`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md) names the
  producer, the version and the digest of each file. This repository's own text
  in that directory is `fixtures/PROVENANCE.md` alone, and it is fork work
  under this grant. The fixtures themselves remain under whatever terms their
  producers published them under, which for GNU gzip and for CPython's `zlib`
  module is the producer's own licence, not zlib's.
* this file, `README.md`, `README.zig.md`, `UPSTREAM.md`, `UPSTREAM.sha256`,
  `FORK-LICENSE.md`, `CHANGELOG.md`, `FORK-NOTES.md`

`flake.lock` is **absent** from this tree, and `build.zig.zon` `.paths` does not
name it: the driver owns locks, and `zig fetch` hashes the named paths, so
naming an absent file would fail the fetch rather than record an absence.
`devenv.lock` is absent for the same reason — `devenv.yaml` pins its nixpkgs
revision in source. `tools/check-provenance.sh` checks both directions: every
path `.paths` names must exist, and a lock that now exists but is not named is
an error.

### Which of those files carry the SPDX tag, and which do not

The fork-authored files that carry `SPDX-License-Identifier: zlib` on their own
first comment line: `build.zig`, `build.zig.zon`, `zig/root.zig`, `tests.zig`,
`smoke.zig`, `consumer/build.zig`, `consumer/src/main.zig`, all six files of
`runtime/`, `tools/check-provenance.sh`, `package.nix`, `flake.nix`,
`devenv.nix`, `devenv.yaml`, `.envrc`, and this file plus `UPSTREAM.md` and
`fixtures/PROVENANCE.md`. That set was read out of the files rather than
assumed.

The rest carry the same grant without a tag, and are named here rather than left
for a scanner to read as unlicensed. Five are comment-capable text whose grant
is this inventory and [`FORK-LICENSE.md`](FORK-LICENSE.md): `zig/translate.h`,
`cross-test.profile.sh`, `.github/workflows/verify.yml`, `.gitignore` and
`consumer/build.zig.zon`. The six documentation and digest records — `README.md`,
`README.zig.md`, `UPSTREAM.sha256`, `FORK-LICENSE.md`, `CHANGELOG.md` and
`FORK-NOTES.md` — are prose and data with no comment position a tag is expected
in, and their grant is the same zlib text.

Upstream's attribution obligation is unaffected by any of this: a consumer who
receives a zlib 1.3.2 binary or static library still owes the Gailly and Adler
notice, and the installed tree carries it. `share/licenses/zlib/` holds
`src/LICENSE` and `src/zlib.h` — upstream's own grant, twice — together with
`src/README`, `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`,
`FORK-NOTES.md` and `CHANGELOG.md`: nine files, exactly `licence_records` in
`build.zig:326-336`, which is also what `package.nix` installs because it runs
the same `zig build install`.