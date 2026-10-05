<!--
SPDX-License-Identifier: zlib
See FORK-LICENSE.md for what that identifier covers.
-->

# Upstream

Which upstream this SDK is built from, what was taken from it byte for byte,
what was generated rather than taken, and what is deliberately absent.

## Canonical source

| | |
|---|---|
| Project | zlib, by Jean-loup Gailly and Mark Adler |
| Authoritative site | <https://zlib.net/> |
| Version | **1.3.2** |
| Release date | 2026-02-17 |
| Import form | release source tree, unpacked into `src/` |

The version and the date are `SOURCE-CONFIRMED`, read out of the imported files
rather than out of a web page this repository never fetched:

* `src/zlib.h:2` — `version 1.3.2, February 17th, 2026`
* `src/zlib.h:44` — `#define ZLIB_VERSION "1.3.2"`
* `src/zlib.h:45` — `#define ZLIB_VERNUM 0x1320`
* `src/README:3` — "zlib 1.3.2 is a general purpose data compression library"
* `src/ChangeLog:5` — `Changes in 1.3.2 (17 Feb 2026)`

The home page is `https://zlib.net/`, stated in `src/README:23-24`.

### What is *not* recorded here, and why

**No sha256 of the release tarball, and no commit SHA.** Neither is written in
this table, because neither can be read out of anything in this repository:

* The tarball itself is not present. `src/` is the *unpacked* tree, and no
  `.tar.gz` was kept, so its digest cannot be computed here even in principle —
  only the digests of the 254 extracted files can, and those are what
  [`UPSTREAM.sha256`](UPSTREAM.sha256) holds.
* The upstream Git repository is not part of this import. zlib's canonical
  source is the tarball, not a clone, so there is no commit SHA to record.

This is an honest gap rather than a missing field: a digest written here would
be a number this repository cannot reproduce and could not check, and a digest
guessed from a remembered download page would be worse than an absence. What
*is* checkable is the imported tree, and that is what is recorded.

| | |
|---|---|
| Imported files | **254** |
| Aggregate digest | `27bb64c4dea284cac7130e7df0ef617901f38de43d91479e6d62fbafcc107dd4` |

The aggregate is the sha256 of the digest column of `UPSTREAM.sha256`, in file
order. It is derived, not asserted:

```sh
awk '/^[0-9a-f]{64}  / { print $1 }' UPSTREAM.sha256 | sha256sum
```

It changes if any entry is added, removed, reordered or edited, and anyone
holding `UPSTREAM.sha256` can recompute it with that one command.
`tools/check-provenance.sh` recomputes it and compares it against the value
recorded in this file, so the two records cannot disagree.

**`STATUS`: `SOURCE-CONFIRMED`.** Every digest in this repository was computed
by reading bytes that are present. No build, test, smoke run or cross-target
check was executed to produce any of them; the observed runs are recorded in
[`README.md`](README.md) and are `PENDING-VERIFICATION` until the driver
observes them.

## What upstream is

A general-purpose DEFLATE compression library implementing three RFCs: **RFC
1950** (the zlib stream format), **RFC 1951** (the DEFLATE format) and **RFC
1952** (the gzip file format). The three specification texts are vendored in the
tarball itself, at `src/doc/rfc1950.txt`, `src/doc/rfc1951.txt` and
`src/doc/rfc1952.txt`, and they are what this repository's behavioural tests
read when they state an expected answer.

The library has no external dependency beyond a C compiler and, where the
platform configuration asks for it, `unistd.h` and `stdarg.h`.

## What is in the imported tree

254 files under `src/`, imported whole. Nothing is dropped for size, and
nothing is dropped for being uncompiled by this fork.

| Path | What it is |
|---|---|
| 15 `.c` files in the root of `src/` | the nine `OBJZ` units and the six `OBJG` units — the whole compiled closure |
| `zlib.h` | the public header, and one of the two files carrying zlib's grant |
| `zconf.h`, `zconf.h.in` | the configured header and the `configure` template it is generated from |
| `crc32.h`, `deflate.h`, `gzguts.h`, `inffast.h`, `inffixed.h`, `inflate.h`, `inftrees.h`, `trees.h`, `zutil.h` | internal headers |
| `doc/rfc1950.txt`, `rfc1951.txt`, `rfc1952.txt`, `algorithm.txt`, `txtvsbin.txt`, `crc-doc.1.0.pdf` | the specifications and notes |
| `zlib.3`, `zlib.3.pdf` | the manual page, in troff and PDF |
| `contrib/` | 155 files of contributed bindings and tools, none of it compiled |
| `Makefile`, `Makefile.in`, `configure`, `treebuild.xml`, `BUILD.bazel`, `MODULE.bazel`, `INDEX` | the Unix build, the CMake build, the Bazel build and the file index |
| `test/example.c`, `test/minigzip.c`, `test/infcover.c` | upstream's own build-testing programs |
| `contrib/` | 130-odd files of contributed bindings and tools, none of it compiled |
| `examples/` | eight standalone example programs |
| `amiga/`, `msdos/`, `os400/`, `qnx/`, `watcom/`, `win32/` | retained platform build systems, none of them compiled |
| `ChangeLog`, `FAQ`, `INDEX`, `README`, `README-cmake.md` | upstream's own documentation |
| `make_vms.com` | the VMS build |

Per-file digests are in [`UPSTREAM.sha256`](UPSTREAM.sha256), which is the
complete set and not a selection.

### Retained but not compiled

`contrib/`, `examples/`, `amiga/`, `msdos/`, `os400/`, `qnx/`, `watcom/`,
`win32/`, `test/` and the two upstream build systems that this package does not
use are all present and all digested. They are retained deliberately:

* `test/example.c` and `test/minigzip.c` are upstream's own build-testing
  programs. `build.zig` does not compile them — this package's tests are its own
  — but they are the programs `src/README:11-14` tells a user to build, and a
  tree that dropped them would not be upstream's tree.
* `contrib/` contains material under **its own terms**, not zlib's. See
  [`NOTICE.md`](NOTICE.md), "Per-file exceptions", which inventories it.

## The compiled closure, as upstream lists it

`src/Makefile.in:59-61` names the objects that make `libz.a`, and that is the
closure this SDK compiles — read out of upstream rather than derived:

* **`OBJZ` (9):** `adler32.o crc32.o deflate.o infback.o infffast.o inflate.o
  inftrees.o trees.o zutil.o`
* **`OBJG` (6):** `compress.o uncompr.o gzclose.o gzlib.o gzread.o gzwrite.o`
* **`OBJC` (15):** the two lists concatenated — what `build.zig` compiles as
  `core_sources` (the nine) plus `lib_sources` (the six).

`src/Makefile.in:32-36` names the artifacts those objects become:
`STATICLIB=libz.a`, `SHAREDLIB=libz.so`, `SHAREDLIBV=libz.so.1.3.2`,
`SHAREDLIBM=libz.so.1`. `build.zig` reproduces those file names rather than
inventing a version of its own, which is why `libz.so.1.3.2` is the shared
object this package installs.

## Nothing is vendored from a third party

There is no vendored dependency, no downloaded header and no generated table.
Every file here other than the 254 upstream files and the fixture set in
[`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md) was written for this fork.

## What is generated rather than taken

**One header: `zconf.h`.** `src/zconf.h.in` is the template and
`tools/genzconf.c` is upstream's own generator for it — both are in the tarball
and both are digested. `build.zig` compiles `genzconf.c` for the host and runs
it **for the target being built**, so `HAVE_UNISTD_H` and `HAVE_STDARG_H` are
resolved from the target's platform configuration and never from the machine
that happened to run `zig build`.

`src/zconf.h` is also present in the tarball, pre-generated by upstream for a
POSIX host, and it is digested as an upstream file. It is **not** what this
build compiles against: `build.zig` puts the generated directory ahead of `src/`
on four include lines, so `#include "zconf.h"` at `src/zlib.h:37` resolves to
the generated header for the target and never to upstream's checked-in copy.
`UPSTREAM.sha256` records both `src/zconf.h` and `src/zconf.h.in` with the same
digest — they are byte-identical in this release, which is a fact about the
release and not an assumption this package makes.

Under `-Dsystem=true` nothing is generated: the build links the installed
library and translates **the installed headers**, per `AGENTS.md` §4 and
`WISDOM.md` W14. Bundled new-release headers against an older installed library
compile and fail silently, so this package never does it.

## There is an upstream test tree, and this package does not claim to run it

`src/test/` carries three programs — `example.c`, `minigzip.c` and
`infcover.c` — and `src/README:11-14` points a user at two of them. Those are
upstream's *build*-testing programs: `minigzip.c` is the minimal
gzip-like front end `src/Makefile.in` builds for `make test`, and `infcover.c`
exists to drive coverage instrumentation through the `inf*.c` files.

This SDK therefore makes **no claim** to ship, build or run an upstream test
suite, and no build step fetches one to stand in for it: a fetched suite would be
a different source tree from the release this SDK pins, with no recorded digest.
`src/test/` stays in the tree, digested and unmodified, because it is part of
upstream's release — not because anything here runs it.

This package's own behavioural tests are in `tests.zig`, and their oracle is
**not** a round trip: it is GNU gzip 1.13's independent RFC 1952 encoder, zlib
1.2.13's cross-release output, and the three RFC texts vendored under
`src/doc/`. See [`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md).

## The preserved upstream README

The tarball ships a file called `README`, which is upstream's own release note
and **not** a fork README. It is preserved twice, unaltered:

* `src/README` — the imported original, exactly as the tarball carries it, 5291
  bytes, and digested in `UPSTREAM.sha256`.
* `README.upstream.md` — the same bytes under the name the rest of this
  repository uses for a preserved upstream README.

`tools/check-provenance.sh` fails if the two ever differ. The canonical fork
document is [`README.md`](README.md); upstream's own release note is
`README.upstream.md`, and it is installed alongside the fork's records because
`build.zig`'s `licence_records` names it.

## Import mechanism

A release source tree, imported whole. There is no upstream Git history in this
tree, no commit SHA to record, and no patch series: the tree either matches the
import or a deviation is recorded. `UPSTREAM.sha256` plus the exact-file-set
check in `tools/check-provenance.sh` are what make that checkable rather than
asserted.

If a future wave re-syncs to another release, the correct sequence is: obtain
the new release source, replace the imported files, regenerate `zconf.h` through
`tools/genzconf.c`, update `UPSTREAM.sha256` (and the aggregate in this file),
`UPSTREAM.md`, `NOTICE.md` and `README.md`, and add a numbered `CHANGELOG.md`
entry — in one change. The release digest belongs in this table **only** once it
has been read from a file someone can point at; it is absent today because
nothing in this repository carries it.