#!/usr/bin/env bash
# Source-integrity check for the zlib SDK.
#
# Four questions, all answerable without a compiler:
#
#   1. Do the 254 upstream files still hash to the digests UPSTREAM.sha256
#      records?
#   2. Is the native file set exactly that set -- no missing, extra or renamed
#      file under src/?  A plain checksum run cannot see an addition.
#   3. Does the fixture set still match the digests fixtures/PROVENANCE.md and
#      tests.zig cite?
#   4. Is the preserved upstream README still byte-identical to the imported
#      README, and is zlib's own grant still where the records say it is?
#
# This is a provenance gate, not a build gate. Nothing here compiles, links or
# runs a target binary; it is the check that an edit to the canonical native
# source cannot pass as a routine change.
#
# Usage: tools/check-provenance.sh   (run from anywhere in the repository)
#
# SPDX-License-Identifier: zlib
# See FORK-LICENSE.md for what that identifier covers.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "$1" >&2
    exit 1
}

# 1. Bytes. `--quiet` prints only the lines that failed, and with `pipefail` in
#    force there is no `head` in this pipeline to turn a success into a
#    SIGPIPE.
sha256sum -c --quiet UPSTREAM.sha256 || fail "an upstream file no longer matches UPSTREAM.sha256"
echo "all 254 upstream files match UPSTREAM.sha256"

# 2. File set. UPSTREAM.sha256 is the complete record of src/, so comparing the
#    two listings catches an addition as well as a deletion, which a checksum
#    run alone cannot do.
expected_tree=$(awk '/^[0-9a-f]{64}  / { print $2 }' UPSTREAM.sha256 | grep -E '^src/' | LC_ALL=C sort)
actual_tree=$(find src -type f | LC_ALL=C sort)
if [ "$expected_tree" != "$actual_tree" ]; then
    echo "the native file set differs from the recorded one:" >&2
    diff -u <(echo "$expected_tree") <(echo "$actual_tree") >&2 || true
    echo >&2
    echo "An intentional change to the native source needs an observed failure, a" >&2
    echo "small causal patch, an explicit per-file deviation record in NOTICE.md," >&2
    echo "updated digests here, and a CHANGELOG.md entry in the same change." >&2
    exit 1
fi
echo "the native file set is exactly the recorded 254 files"

# 3. The fixture set. `fixtures/PROVENANCE.md` is the record that names each
#    fixture's producer and digest, and `tests.zig`, `smoke.zig` and
#    `consumer/src/main.zig` all cite it. Those three files embed the fixtures
#    with `@embedFile` and state two recorded checksums as literals, so a
#    fixture that silently changed would turn an independent known answer into
#    a round trip without any test failing. The digests below are the ones
#    PROVENANCE.md records; each is re-derived here.
#
#    This tree has no `fixtures/SHA256SUMS`, so the list is written out rather
#    than read from a manifest that a future regeneration would have to keep in
#    step with two other files anyway.
#
# 3a. The payload.
printf '%s  %s\n' \
    7375379c4bbd9f98d872f9e72347f97a08758c38db6eb9895fd118b62d942804 fixtures/plain.bin \
    | sha256sum -c --quiet - || fail "fixtures/plain.bin no longer matches fixtures/PROVENANCE.md"

# 3b. GNU gzip 1.13's RFC 1952 streams. An independent encoder: gzip does not
#     link libz, so a change to any of these means the producer changed, not
#     that this build's decoder changed.
printf '%s  %s\n' \
    5bd9f7b5cdf694fb33016e22dae6db4e439b9a5992e3e838d5809d5980e7a696 fixtures/gzip/gzip-n1.bin \
    96ee1cbfb22e56e2972f2c6e28ec572b8c796a56d58671f92a0a5486b177d3aa fixtures/gzip/gzip-n9-name.bin \
    ea334068f0af2902fd4e650ea4b3cf450a837b5a0dbe3417d76f4a726ebbe06f fixtures/gzip/gzip-n9.bin \
    f8e726322c41da5b361c269e35db1ceb578a9eec2915435198a81579e76e9dcc fixtures/gzip-version.txt \
    | sha256sum -c --quiet - || fail "a fixtures/gzip stream no longer matches fixtures/PROVENANCE.md"

# 3c. zlib 1.2.13's RFC 1950 and bare-deflate streams, and the two recorded
#     checksums that three separate source files state as literals. The two
#     raw files are listed separately even though they share a digest: they are
#     two files, and a change to either has to be caught.
printf '%s  %s\n' \
    86ba4b600c4df6c811c71fc768a1a578da01a08dd6870cb444eaea3a168abb08 fixtures/pyzlib/zlib-n1.z \
    921cdadb9a6cd09a90495a1de573e73f41b92f7941d1c5b8c9edccba2ddfc217 fixtures/pyzlib/zlib-n6.z \
    4b6dfdf3838d59eebe005f5cbdfa26b2df37833b4ed1bf504a47235c061b21c9 fixtures/pyzlib/zlib-n9.z \
    695f95c24e3cb7dc7284e4f58dd8a1f519a94fa1aeeb1ab27d5b5afff4a45c46 fixtures/pyzlib/raw-n6.bin \
    695f95c24e3cb7dc7284e4f58dd8a1f519a94fa1aeeb1ab27d5b5afff4a45c46 fixtures/pyzlib/raw-n9.bin \
    fec98739daa116991bd0d946e7c90b3d3dd92ec74a5214ad5ac11ea052485fd4 fixtures/pyzlib/checksums.txt \
    c21698334b1e2308b8556ac1d10402342b8d3e837f65fa1c431eb23392824b1d fixtures/pyzlib/zlib-runtime.txt \
    | sha256sum -c --quiet - || fail "a fixtures/pyzlib fixture no longer matches fixtures/PROVENANCE.md"

# 3d. The producer version strings the interoperability claim rests on. gzip
#     1.13 and zlib 1.2.13 are named in tests.zig, smoke.zig and
#     consumer/src/main.zig as the implementations that produced the streams
#     above; if a record were rewritten to name a different version, those
#     claims would silently become false.
for pair in 'gzip 1.13:fixtures/gzip-version.txt' '1.2.13:fixtures/pyzlib/zlib-runtime.txt'; do
    want=${pair%%:*}
    file=${pair#*:}
    got=$(tr -d '\n' < "$file")
    [ "$got" = "$want" ] ||
        fail "$file records '$got', but the fixture records name '$want'"
done
echo "the 12 fixture files match the digests in fixtures/PROVENANCE.md"

# 4a. The import must be recorded identically in both records, so the two files
#     cannot disagree about which upstream release this is. What is recorded
#     here is an aggregate of the *imported file set*, not the tarball's
#     published digest: no tarball was ever held in this repository, and
#     UPSTREAM.md, "Canonical source", says so rather than filling the gap with
#     a number nobody here can compute.
expected_count=$(awk '/^[0-9a-f]{64}  / { n++ } END { print n + 0 }' UPSTREAM.sha256)
[ "$expected_count" = "254" ] ||
    fail "UPSTREAM.sha256 records $expected_count files, and the rest of this script checks 254"

# The aggregate below is *derived*, not asserted: it is the sha256 of the file's
# own digest column, in file order. It changes if any entry is added, removed,
# reordered or edited, and anyone holding UPSTREAM.sha256 can recompute it with
# one command. UPSTREAM.md records the same value, so the two files cannot
# disagree about which upstream release this tree was imported from.
recorded_aggregate=$(grep -m1 -oE '[0-9a-f]{64}' UPSTREAM.md || true)
actual_aggregate=$(awk '/^[0-9a-f]{64}  / { print $1 }' UPSTREAM.sha256 | sha256sum | cut -d' ' -f1)
[ -n "$recorded_aggregate" ] ||
    fail "UPSTREAM.md records no sha256 aggregate of UPSTREAM.sha256"
[ "$recorded_aggregate" = "$actual_aggregate" ] ||
    fail "UPSTREAM.md records $recorded_aggregate but UPSTREAM.sha256 aggregates to $actual_aggregate"
echo "the 254-entry import aggregate is recorded consistently: $recorded_aggregate"

# 4b. The preserved upstream README. README.upstream.md is the exact bytes of
#     the tarball's README; the copy in the source tree is the imported
#     original.
cmp -s src/README README.upstream.md ||
    fail "src/README and README.upstream.md are no longer byte-identical"
echo "README.upstream.md is byte-identical to the imported upstream README"

# 4c. zlib's own grant, in the two files that carry it and in the records.
#     The zlib licence obliges an altered source to be plainly marked, so the
#     check has to be able to tell "unmodified" from "modified and marked".
for file in src/LICENSE src/zlib.h; do
    grep -q '(C) 1995-2026 Jean-loup Gailly and Mark Adler' "$file" ||
        fail "the upstream copyright notice is missing from $file"
done
grep -q 'Altered source versions must be plainly marked as such' src/LICENSE ||
    fail "src/LICENSE no longer carries zlib's altered-source clause"
grep -q 'Altered source versions must be plainly marked as such' src/zlib.h ||
    fail "src/zlib.h no longer carries zlib's altered-source clause"
for file in NOTICE.md README.md FORK-LICENSE.md; do
    grep -q 'Jean-loup Gailly and Mark Adler' "$file" ||
        fail "the upstream copyright notice is missing from $file"
done
# zlib's own disclaimer, as zlib writes it. FORK-LICENSE.md:62 reproduces
# "This software is provided 'as-is', without any express or implied warranty."
# verbatim from src/LICENSE:5-6. The matcher previously looked for the
# BSD-style uppercase phrasing "THE SOFTWARE IS PROVIDED .AS-IS., WITHOUT ANY
# EXPRESS OR IMPLIED", which appears in no zlib-licensed file in this tree; the
# text that does appear at FORK-LICENSE.md:74-76 is the grant for
# `src/contrib/dotzlib/`, a different licence in a different file.
grep -q "This software is provided 'as-is', without any express or implied" FORK-LICENSE.md ||
    fail "FORK-LICENSE.md does not reproduce the zlib warranty disclaimer"
echo "the upstream zlib notice is present in src/LICENSE, src/zlib.h and the records"

# 4d. The version the package claims, against the three places the imported
#     header states it. A manifest that drifted from the source it describes
#     would make build.zig.zon, zlib.pc and the shared object's file name
#     describe three different releases.
grep -q '^    .version = "1.3.2",' build.zig.zon ||
    fail "build.zig.zon no longer records .version = 1.3.2"
grep -q '#define ZLIB_VERSION "1.3.2"' src/zlib.h ||
    fail "src/zlib.h no longer defines ZLIB_VERSION 1.3.2"
grep -q '#define ZLIB_VERNUM 0x1320' src/zlib.h ||
    fail "src/zlib.h no longer defines ZLIB_VERNUM 0x1320"
echo "the pinned version is recorded consistently: 1.3.2"

# 4e. build.zig.zon .paths is the package's file filter, and the one rule that
#     governs it is that every path it names must exist: `zig fetch` hashes the
#     named paths, so naming a path that is absent fails the fetch rather than
#     recording an absence. This reads the names out of the manifest rather than
#     from a list written here, so the check cannot fall out of step with the
#     manifest it is checking. It runs in both directions: a named path that is
#     missing, and a lock file that now exists but is not named.
declared_paths=$(sed -n '/^    .paths = .{/,/^    },/p' build.zig.zon |
    sed -n 's/^        "\(.*\)",$/\1/p')
[ -n "$declared_paths" ] || fail "no .paths entries were read out of build.zig.zon"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$path" ] ||
        fail "build.zig.zon .paths names $path, and it does not exist"
done <<< "$declared_paths"
echo "all $(printf '%s\n' "$declared_paths" | grep -c .) paths build.zig.zon .paths names exist"

# Lock files belong to the driver. Once one exists, include it in the package
# rather than silently omitting the dependency pins from the published source.
for lock in flake.lock devenv.lock; do
    if [ -e "$lock" ]; then
        printf '%s\n' "$declared_paths" | grep -qx "$lock" ||
            fail "$lock now exists, so build.zig.zon .paths must name it in the same change"
    fi
done
echo "all present lock files are included in .paths"

# 4f. The fixture provenance record is itself cited by three source files, so a
#     deletion would leave those citations dangling and the fixture set
#     unaudited.
for file in tests.zig smoke.zig consumer/src/main.zig; do
    grep -q 'fixtures/PROVENANCE.md' "$file" ||
        fail "$file cites fixtures/PROVENANCE.md but no longer does"
done
[ -f fixtures/PROVENANCE.md ] || fail "fixtures/PROVENANCE.md is missing"
echo "fixtures/PROVENANCE.md is present and is cited by tests.zig, smoke.zig and consumer/src/main.zig"

echo "provenance checks passed"