<!--
SPDX-License-Identifier: zlib
See NOTICE.md for what that identifier covers.
-->

# FORK-LICENSE.md — the grant for this fork's own files

[`NOTICE.md`](NOTICE.md) is the inventory: which files are upstream's, which are
this fork's, and which term covers each. This file is the grant itself, for the
second group only.

## 1. The native source is not covered by anything below

The 254 files under `src/` are zlib's, whole, and never edited. They are
**zlib-licensed, Copyright (C) 1995-2026 Jean-loup Gailly and Mark Adler**,
under the grant in `src/LICENSE` and in the header block at `src/zlib.h:1-29`.
Nothing in this file re-grants, narrows, widens or conditions that term, and
nothing here asserts that Jean-loup Gailly, Mark Adler, Gilles Vollant or any
named contributor wrote, reviewed or endorsed a line of fork code.

Two facts about that grant belong here rather than only in the inventory,
because they constrain what this fork may do with the native source:

* **The zlib grant has an altered-source condition** (condition 2 of
  `src/LICENSE`). This fork has not altered any file under `src/`, so the
  condition is not currently engaged; a future native change must mark the file
  plainly and record the deviation in `NOTICE.md`.
* **`src/contrib/` is not covered by the zlib grant.** It is 155 files of
  contributed material, two directories of which carry their own terms — the
  Info-ZIP licence for `minizip/` and the Boost Software License 1.0 for
  `dotzlib/`. `NOTICE.md`, "Per-file exceptions", inventories it. None of it is
  compiled into any artefact this package delivers.

## 2. The fork-authored material

Everything else in this repository — the Zig build, the typed module and its
tests, the example, the consumer package, the runtime-loading route, the
packaging, the integrity script, the fixture provenance record and the
documentation — was written for this fork. The runtime-loading route is the six
files under `runtime/`: the reusable loader, this SDK's descriptor, the build
half that wires them together, the build-time generator, and the two C files
that supply the synchronization the descriptor binds. All six are fork work
under this grant; none of them is upstream material and none is derived from a
third-party source.

**One file in the fork directories is not fork work, and saying so is the
point:** `tools/genzconf.c` is upstream's own `zconf.h` generator, shipped in
the tarball and covered by section 1. It lives beside `tools/check-provenance.sh`
because `build.zig` compiles both the same way, and a reader of the directory
listing deserves to know that one of its two files is Gailly and Adler's.

### Grant

**Those files are released under the zlib License**, matching the primary
upstream term of this project, whose text is:

```
zlib License

Copyright (C) 1995-2026 Jean-loup Gailly and Mark Adler

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use of
this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to
the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but is
   not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

Jean-loup Gailly        Mark Adler
jloup@gzip.org          madler@alumni.caltech.edu
```

The three conditions apply to these files exactly as they apply to upstream's,
and the same obligation MIT would impose applies here: keep the notice with
copies of the fork's files.

### Authority for that grant

The owner of this repository authorized per-project licensing for fork-authored
additions as part of the SDK contract migration, with the term chosen per
project to match that project's primary upstream terms where that is
appropriate. zlib's primary upstream term is the zlib licence, so the zlib
licence is the choice. The authorization is recorded here and in `NOTICE.md`;
the term above is the owner's, reached by that authorization and not by any
upstream grant.

**The copyright line above is zlib's own and it is quoted, not claimed.** The
fork-authored files are covered by the permission statement in that text; the
copyright attribution in it belongs to Gailly and Adler and is reproduced here
because the grant is the zlib licence. This repository asserts no authorship
over zlib's name, copyright or work, and the owner of this repository is
deliberately not named as an individual holder: no individual copyright holder
is invented here.

### SPDX identifier

```
zlib
```

The plain registered identifier, with no `LicenseRef-` wrapper. That is a
deliberate distinction, not a shortcut. A fork whose primary term carries added
conditions needs an identifier that names them, because a consumer scanning for
a bare identifier would otherwise stop reading and miss the conditions. **zlib's
term does carry a condition worth naming** — condition 2, that altered sources
be plainly marked — but the `zlib` identifier *is* the identifier that names it:
it is the SPDX identifier for this exact three-condition text, and inventing a
`LicenseRef-` wrapper for it would misrepresent a standard licence as a private
variant. The condition is stated in this file and in `NOTICE.md`, and the
provenance gate greps for its text in both upstream files, so it cannot be lost
silently.

Every fork-authored **source, build, packaging and script** file carries
`SPDX-License-Identifier: zlib` on its own first comment line; the file list is
in `NOTICE.md`. The documentation and digest records do not carry a tag: they
are prose and data, and `NOTICE.md` names each of them explicitly so that a
scanner finding no identifier in `README.md` reads a recorded reason rather than
an apparent gap.

### What this does not do

* It does not re-license, sublicense or add a condition to any file under
  `src/`.
* It does not extend the zlib grant to the material under `src/contrib/` that
  carries its own terms, and it does not narrow those terms.
* It does not assert that Jean-loup Gailly, Mark Adler or any contributor
  listed in `src/contrib/README.contrib` authored, reviewed, endorsed or is
  affiliated with the fork's files.
* It does not discharge zlib's attribution obligation. A consumer who ships a
  zlib 1.3.2 binary, static or shared library, or the headers, still owes the
  Gailly and Adler notice; see `NOTICE.md` for where it travels.
* It does not claim that the zlib licence is the only term the owner could have
  chosen for independently authored work. It is the term chosen, and it happens
  to match upstream's.

## 3. Material carried but not authored here

**One category, and it is the fixture set.** `fixtures/` contains bytes
produced by other programs — GNU gzip 1.13 and CPython's `zlib` module over
zlib 1.2.13 — over a payload this repository also stores. Those bytes are not
authored here and are not covered by this grant. They remain under whatever
terms their producers published them under, and
[`fixtures/PROVENANCE.md`](fixtures/PROVENANCE.md) names the producer, the
version and the digest of every one of them. The only text this repository
authored in that directory is `fixtures/PROVENANCE.md` itself.

Apart from the fixture set there is **no** other carried material. This
repository vendors no third-party library, no downloaded header and no external
data file. The 254 files listed in `UPSTREAM.sha256` are the complete upstream
material, and nothing was added to them.

The two files this build generates are not carried material either, and the
distinction is worth keeping exact rather than dropping a category to make the
sentence short. Under `-Druntime`, `runtime/generate.zig` writes the dispatch
and its patched translation through `Run.addOutputFileArg`, so both land in the
build cache rather than in this tree, and they are built from the translation of
`zig/translate.h` and upstream's own headers that this same build has just
produced for the target being built. Nothing is fetched to make them, no
third-party code is in them, and neither is installed or shipped: every file
under `runtime/` in this tree is a fork-authored file under section 2.

The generated `zconf.h` is the same case and is called out because it is
generated from an upstream template by an upstream generator: `build.zig`
compiles `tools/genzconf.c` — upstream's file — for the host and runs it for the
target being built. The result is upstream's own configuration of upstream's own
template, placed in the build cache and never in this tree. It is not a fork
artefact and is not a fork modification of anything.

## 4. Why a separate file at all

`NOTICE.md` names which fork-authored files carry an `SPDX-License-Identifier`
line and which carry the same grant in prose without one. This file exists so
that the authority, the grant text and the limits of that grant live in one
place, next to the inventory rather than scattered across the files themselves
— and so that the one file in a fork directory that is *not* fork work,
`tools/genzconf.c`, is named where the distinction is made rather than left for
a reader to infer from a directory listing.