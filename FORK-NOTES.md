# FORK-NOTES.md

Decisions taken while building this package, the reasoning behind them, and the
issues met along the way. Entries are written in the horizon-learning shape —
**condition, symptom, resolution, targets bound** — so a later wave in another
directory, another library or another toolchain version can apply one without
re-deriving it.

Nothing here is a verification result. Every statement is
`SOURCE-CONFIRMED` (read out of a file) or `CONSTRAINT` (a binding design rule
with no observation behind it). The driver's runs live in the workspace ledger.

---

## 1. Decisions

### 1.1 `zconf.h` is generated for the target, not for the machine

**Decision.** `build.zig` compiles upstream's `tools/genzconf.c` for the host and
runs it **for the target being built**, then places the generated directory
ahead of `src/` on four include lines.

**Why.** `src/zconf.h.in` is the template and `src/zconf.h` ships alongside it,
already configured for a POSIX host. `build.zig` does not use the checked-in
copy: `HAVE_UNISTD_H` and `HAVE_STDARG_H` decide what the header declares, and a
header configured for the machine that ran `zig build` describes that machine,
not the target.

**Why it is not a native-source deviation.** The generated header lands in the
build cache, never in this tree. No file under `src/` is touched, and
`UPSTREAM.sha256` records both `src/zconf.h` and `src/zconf.h.in` with the same
digest because in this release they are byte-identical — a fact about the
release, not an assumption this package makes.

**Targets bound.** Zig 0.16.0. The specific consequence is the
`x86_64-windows-gnu` cell of the `check` matrix: `src/zconf.h:488-490` reaches
`<unistd.h>`, and `src/gzguts.h:46-49` reaches `<stddef.h>`, so a header
generated for POSIX but compiled for Windows describes a Windows library
including a header upstream's Windows path never expects.

### 1.2 Upstream's build systems are kept but never invoked

**Decision.** `configure`, `Makefile.in`, `CMakeLists.txt`, `BUILD.bazel`,
`MODULE.bazel` and the six platform makefiles all travel, digested and
unmodified. None is run.

**Why.** Two separate reasons, and they are different. The vendored trees are
part of upstream's release, and a tree that dropped them would not be upstream's
tree — the whole directory ships precisely so that a build which needed a file
outside the closure would have to edit upstream to get it. The build systems are
not used because `build.zig` is the one build graph: a second entry point is a
second place for a flag to disagree.

### 1.3 Artifact names are upstream's

**Decision.** The package installs `libz.a` or `libz.so.1.3.2` with the
`libz.so.1` soname, from `src/Makefile.in:32-36`.

**Why.** `build.zig.zon`'s `.name` is `.zlib`, the registered module is
`dep.module("zlib")` and `dep.artifact("zlib")` is the same string. That string
is what makes Zig emit `libz.a`, which is what a C consumer's `-lz` resolves. A
wrapper's own naming would break both at once.

### 1.4 `-std=gnu99` is pinned

**Decision.** Every C translation unit is compiled with `-std=gnu99`.

**Why.** Upstream's `configure` sets no `-std=` at all and inherits whatever the
host compiler defaults to. A build whose dialect is a fact about the machine
running `zig build` is not reproducible. `gnu99` rather than `c99` because
`src/configure` itself passes GNU extensions to the compiler for its test
programs, so `c99` would be stricter than upstream's own build.

**Targets bound.** Zig 0.16.0 and every check target in the matrix.

### 1.5 `upstream's test tree` is retained, not run

**Decision.** `src/test/` — `example.c`, `minigzip.c`, `infcover.c` — is
retained, digested and unmodified. `build.zig` compiles none of them, and this
package claims no upstream test suite.

**Why.** Those are upstream's *build*-testing programs: `minigzip` is the
minimal gzip-like front end `src/Makefile.in` builds for `make test`, and
`infcover` exists to drive coverage through the `inf*.c` files. `src/README:11-14`
points a user at two of them. Claiming to "run upstream's tests" when what
exists is a build check would be a different claim from the truth, and fetching
a real suite would mean a different source tree than the release this package
pins, with no recorded digest.

### 1.6 Two defaults for `-Dlinkage`, not one derived default

**Decision.** `-Dlinkage` defaults to `.static` in bundled mode and `.dynamic`
in system mode.

**Why.** Two separate histories. The bundled graph compiled a static archive
before the option existed and must keep doing so, because `src/Makefile.in:38`
names `STATICLIB=libz.a`. `linkSystemLibrary`'s own default is `.dynamic`, and
system mode must keep that too. Deriving one from the other would silently
change a consumer's linkage **in the mode the option was not written for** —
which is the failure mode nobody would notice until a consumer's `.so` stopped
being found.

### 1.7 The interoperation oracle is stated at the strength it has

**Decision.** The fixture set is two producers, and the documentation says which
is which:

* `fixtures/gzip/*.bin` — **GNU gzip 1.13**, whose deflate encoder is its own
  and does not link libz. **Genuinely independent.**
* `fixtures/pyzlib/*` — **zlib 1.2.13**, the reference implementation one
  release older. **Cross-release, not a second encoder.**

**Why.** Writing "two independent implementations" would be false, and it would
be false in the direction that matters: a reader who believed it would rate the
interoperation evidence higher than it deserves. `fixtures/PROVENANCE.md` and
[`README.zig.md`](README.zig.md) §10 both say it in those words.

### 1.8 No fixture of this build's own output

**Decision.** No compressed stream in the fixture set was produced by
`compress2`.

**Why.** A stream this build made and this build read back proves the two halves
agree with each other and nothing else. Round trips appear in `tests.zig` and
`smoke.zig` and they **supplement** the oracles; none exists only to show that
what this SDK compressed can be decompressed again.

---

## 2. Issues met, and what was done

### 2.1 `fixtures/PROVENANCE.md` was cited by three files and did not exist

**Condition.** `zlib/smoke.zig:12`, `zlib/tests.zig:38,60,333,421,1130` and
`zlib/consumer/src/main.zig:24` all name `fixtures/PROVENANCE.md` as the record
that gives each fixture its producer and digest.

**Symptom.** The record was absent. Every citation pointed at nothing, and the
fixture set had no provenance anywhere in the tree: the two producer versions
and the two recorded checksums were stated in three source files as literals,
with nothing recording where those literals came from.

**Resolution.** The record is written. `fixtures/PROVENANCE.md` names, for every
file: the producer, the version, the exact command, the size and the digest — and
states which producer is independent and which is the reference implementation
at a different release.
`tools/check-provenance.sh` now checks all twelve fixture digests, both producer
version strings, and that the three citing files still cite the record. A
deletion or a silent regeneration fails the gate instead of leaving the
citations dangling.

**Targets bound.** None — this is a repository-integrity rule, not a toolchain
one.

### 2.2 `build.zig.zon` `.paths` did not name `fixtures`

**Condition.** `tests.zig` and `smoke.zig` `@embedFile` from `fixtures/`.

**Symptom.** `.paths` is the package's file filter and `zig fetch` hashes the
paths it names. With `fixtures` absent, a package fetched from this manifest
would carry no fixtures: `tests.zig` and `smoke.zig` would compile here and fail
anywhere else. `zstd`'s manifest names `"fixtures"`; this one did not.

**Resolution.** `"fixtures"` is added, with the reason in the comment. The
provenance gate now reads the names out of the manifest itself and checks every
one exists, so the two cannot fall out of step.

**Targets bound.** Zig 0.16.0 — `zig fetch` is what hashes the named paths.

### 2.3 `fixtures/rfc/` was an empty directory

**Condition.** A directory named for RFC test data existed with nothing in it.

**Symptom.** `git` does not track empty directories, so the path existed on this
disk and nowhere else: it would not survive a clone, would not appear in
`.paths`, and no source file cited it.

**Resolution.** Removed. The RFCs themselves are already vendored — as upstream's
own `src/doc/rfc1950.txt`, `rfc1951.txt` and `rfc1952.txt`, digested in
`UPSTREAM.sha256` and carried by `.paths` under `src`. They are the
*specification* side of the oracle and are read directly out of `src/doc/`.
Duplicating a document the repository already vendors byte for byte into
`fixtures/` would create two copies that could drift, which is a worse failure
than the one it fixes.

**Targets bound.** None.

### 2.4 No release digest, and no filling of the gap

**Condition.** `UPSTREAM.md` must record which upstream release this is.

**Symptom.** The obvious fields — the tarball's SHA-256, the upstream commit —
cannot be produced. `src/` is the *unpacked* release and no `.tar.gz` was kept,
so the tarball's digest cannot be computed here even in principle; and zlib's
canonical source is a tarball, not a clone, so there is no commit to name.

**Resolution.** The fields are **absent**, and `UPSTREAM.md` says why in the
table rather than leaving a blank or writing a number this repository cannot
reproduce. What is recorded instead is an **import aggregate**: the SHA-256 of
`UPSTREAM.sha256`'s own digest column, in file order.

```sh
awk '/^[0-9a-f]{64}  / { print $1 }' UPSTREAM.sha256 | sha256sum
```

`27bb64c4dea284cac7130e7df0ef617901f38de43d91479e6d62fbafcc107dd4`

It changes if any entry is added, removed, reordered or edited, anyone holding
the manifest can recompute it with one command, and
`tools/check-provenance.sh` compares the recomputed value against the one in
`UPSTREAM.md` so the two records cannot disagree.

**Why this and not a remembered digest.** A digest copied from a download page
nobody here can re-fetch is a number with no provenance in this repository. If
it is wrong, nothing here finds out. An absent field that says it is absent is a
true statement; a filled field that cannot be checked is not.

**Targets bound.** None.

### 2.5 The BSD cells fail in `translate-c`, in Zig's C translator and not in zlib

**Condition.** `build.zig` gives the typed module a translation step: `zig
translate-c` runs over `zig/translate.h`, which includes `zlib.h` and `zconf.h`
whole. That step is a different compiler from the one that builds the library —
Zig's own aro — and aro reads the **pinned toolchain's** libc headers, not this
tree's. Three places in that toolchain decide the outcome, and all three are
`SOURCE-CONFIRMED`:

* `lib/compiler/aro/aro/pragmas/gcc.zig:149-160` — `parserHandler` consumes
  `diagnostic` and returns for everything else, so a `#pragma GCC <anything
  else>` survives into the C parser.
* `lib/compiler/aro/include/stddef.h:8` — `typedef __SIZE_TYPE__ size_t;` with
  **no** `_SIZE_T_DEFINED_` guard.
* nothing in `lib/compiler/aro` defines `__MIPSEL__` or `__MIPSEB__`.

**Symptom.** On the driver's `cross-test` run of all 53 published targets
(`cross-test`, `zig build test -Dtarget=…`, `run_id 20261005-191614-5696-213`,
exit 1), fourteen cells exit 1 in the `translate-c` step and **every one of
those same logs carries `compile lib zlib Debug TARGET success`**. zlib's
fifteen translation units compile for all 53 targets; only the Zig facade's C
translation does not. Four causes, each with the diagnostic the run printed:

| Cells | Targets | The header that refuses, and why |
|---|---|---|
| 7 | `aarch64-netbsd`, `aarch64_be-netbsd`, `arm-netbsd`, `armeb-netbsd`, `powerpc-netbsd`, `x86-netbsd`, `x86_64-netbsd` | `generic-netbsd/sys/endian.h:74` is `__END_DECLS`, which is `generic-netbsd/sys/cdefs.h:432` → `:413`, `__END_EXTERN_C _Pragma("GCC visibility pop")`. The compiler's own note chain ends at `#pragma GCC visibility pop`, and the diagnostics are `unknown type name 'pragma'`, `unknown type name 'visibility'` |
| 2 | `mips-netbsd`, `mipsel-netbsd` | `mips-netbsd-eabi/machine/endian_machdep.h:8`, `#error neither __MIPSEL__ nor __MIPSEB__ are defined.`, then `generic-netbsd/mips/endian_machdep.h:29` |
| 3 | `arm-openbsd`, `x86-openbsd`, `powerpc-openbsd` | `generic-openbsd/sys/types.h:171-174` guards `typedef __size_t size_t` with `_SIZE_T_DEFINED_`, which aro's `stddef.h:8` never sets: `typedef redefinition with different types ('__size_t' (aka 'unsigned long') vs 'unsigned int')`. Width-bound, not OS-bound: `aarch64-openbsd`, `powerpc64-openbsd`, `riscv64-openbsd` and `x86_64-openbsd` all build |
| 2 | `mips64-openbsd`, `mips64el-openbsd` | `generic-openbsd/mips64/endian.h:39-41`, `#error "__MIPSEL__ or __MIPSEB__ must be defined to define BYTE_ORDER!!!"`, reached because `:32-37` sets `_BYTE_ORDER` only under one of those macros |

**Resolution.** None, and deliberately so. Every one of these is a header this
repository does not own, in a compiler this repository does not ship; the fix
belongs in aro or in the toolchain's BSD headers, not in a `-D` flag here.
Silencing them — a forced include, a `#define` sprayed into `zig/translate.h`,
or dropping the translation for those targets — would produce a facade that
does not describe the header a consumer sees. So the boundary is **recorded**:
the fourteen cells stay in the matrix, keep failing, and are counted as
failures by the harness (`status=fail pass=20 fail=14 build_only=0 partial=19`,
exit 1). Nothing was skipped, no `|| true` was added, and no failed cell was
relabelled. The classified per-cell table and the receipt paths are in the
workspace ledger.

**Targets bound.** Zig 0.16.0's aro, on the fourteen cells named above. A later
Zig that consumes `#pragma GCC visibility` in
`lib/compiler/aro/aro/pragmas/gcc.zig`, or that predefines `__MIPSEL__` /
`__MIPSEB__`, or that guards its builtin `size_t` with `_SIZE_T_DEFINED_`, can
retire part of this entry — so re-run the matrix before repeating it. Nothing
here says those cells are unsupported by zlib; upstream's own `configure` is
not what was run.

---

## 3. Open items for the driver

Each of these is a question this package cannot answer without a gate run, and
each is stated so the driver's next step is unambiguous.

1. **Every gate is `PENDING-VERIFICATION`.** `zig build`, `zig build test` in
   Debug and ReleaseSafe, `zig build smoke`, `zig build check` for all six
   targets and both linkages, `tools/check-provenance.sh`, and `zig build run`
   in `consumer/`. Nothing has been executed.
2. **`.fingerprint` is asserted, not observed.** `build.zig.zon` carries
   `0xf3045050f144607a`, derived from `sha256("zlib-1.3.2-foundation-sdk")`'s
   first eight bytes little-endian so it is reproducible rather than random. The
   *first observed* `zig build` reports the value the toolchain computes for
   `.zlib`; if it differs from this one, this manifest asserts an identifier
   nothing has confirmed, and the driver records the observed value in the same
   change.
3. **The `wasm32-wasi` shared refusal** is asserted in CI as a *specific*
   documented failure. Until that step runs, "the shared object is refused on
   `wasm32-wasi`" is `CONSTRAINT`, not a result — the ledger must distinguish
   "refused for the right reason" from "failed for some other reason".
4. **`-Dsystem=true` is `PENDING-VERIFICATION`** and needs a machine with an
   installed `libz` and its own headers. No system result may substitute for a
   source-package result.
5. **The 53-platform matrix** belongs to `cross-test` on approved scratch, and a
   platform with no runner is `build_only` coverage, never a pass. The matrix has
   now been run once (`run_id 20261005-191614-5696-213`, exit 1); its four causes
   for the fourteen failing cells are §2.5, and the run says nothing about
   `zig build`, `check`, `smoke` or `consumer/`, which are still item 1 above.
6. **`src/zlib.3.pdf` is retained and not installed.** If a future wave wants it
   installed, that is a change to `build.zig`'s `man_pages` list and needs
   upstream's `docs` target dependencies (`groff`, `ps2pdf`) in the reasoning,
   not just a path.