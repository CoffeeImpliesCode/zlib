<!--
SPDX-License-Identifier: zlib
See FORK-LICENSE.md for what that identifier covers.
-->

# Fixture provenance

Every fixture in this directory is a **recorded answer from a producer that is
not this package**. None of them was produced by the facade under test, and
none of them is a round trip of the library's own output. This file is the
record `tests.zig`, `smoke.zig` and `consumer/src/main.zig` cite when they say
that a fixture has a producer: what ran, on what, over what input, and what the
resulting bytes hash to.

`tools/check-provenance.sh` re-derives every digest in the table below and fails
if the file set or a single byte of it has changed. Nothing here was run to
produce this record; every digest is a property of the bytes in the tree.

## The payload

| | |
|---|---|
| File | `plain.bin` |
| Size | 275 bytes |
| sha256 | `7375379c4bbd9f98d872f9e72347f97a08758c38db6eb9895fd118b62d942804` |

This is the single plaintext every fixture below encodes. It is 275 bytes of
ASCII prose followed by a six-byte binary tail, `00 01 02 FD FE FF`, and it
contains an embedded NUL at offset 251 and a `0xff` byte that is not valid
UTF-8. Those two properties are the reason it was chosen: a Zig slice carries
its own length, so a fixture with a NUL in it exercises the whole difference
between a slice and a C string, and a byte above `0x7f` is data on a path that
never inspects encoding. `tests.zig` asserts both survive
(`tests.zig:1132`), and every compressed fixture below decodes back to exactly
these bytes.

## Producer set 1 — GNU gzip 1.13

| | |
|---|---|
| Producer | GNU gzip, version string recorded in `gzip-version.txt` |
| Version | `gzip 1.13` (the whole of `gzip-version.txt`, 10 bytes) |
| sha256 of that record | `f8e726322c41da5b361c269e35db1ceb578a9eec2915435198a81579e76e9dcc` |

GNU gzip's deflate encoder is **not** zlib's: `gzip` implements RFC 1951
itself and never links `libz`. A stream in this set therefore cannot be
produced by `compress2`, and a test that inflates one is exercising this
build's RFC 1951 decoder against another implementation's RFC 1951 encoder.
This is the genuinely independent half of the fixture set.

| File | Command that produced it | Size | sha256 |
|---|---|---:|---|
| `gzip/gzip-n1.bin` | `gzip -1 -n -c plain.bin` | 164 | `5bd9f7b5cdf694fb33016e22dae6db4e439b9a5992e3e838d5809d5980e7a696` |
| `gzip/gzip-n9.bin` | `gzip -9 -n -c plain.bin` | 164 | `ea334068f0af2902fd4e650ea4b3cf450a837b5a0dbe3417d76f4a726ebbe06f` |
| `gzip/gzip-n9-name.bin` | `gzip -9 -N -c plain.bin` | 174 | `96ee1cbfb22e56e2972f2c6e28ec572b8c796a56d58671f92a0a5486b177d3aa` |

`-n` suppresses the original name and the timestamp, which is what makes the
first two streams reproducible. `-N` keeps them, so the third is the one
fixture whose header carries a field beyond the fixed ten bytes: its `FNAME`
field is `plain.bin\0`, followed by `00` for the comment terminator, and the
`MTIME` field is non-zero where the other two are zero. `tests.zig:335` reads
`OS = 3` at byte 9 (the value RFC 1952 §2.3.1 gives a Unix host) and
`tests.zig:420-424` reads `MTIME` out of `gzip-n9-name.bin` for exactly that
reason.

Two of these three files have the same length and different digests, and that
is the point: `-1` and `-9` produce different encodings of the same 275 bytes,
so the decoder is being shown two valid answers rather than one answer twice.

## Producer set 2 — CPython's `zlib` module over zlib 1.2.13

| | |
|---|---|
| Producer | the `zlib` module of CPython 3.13 |
| Linked library | zlib **1.2.13** (the whole of `zlib-runtime.txt`, 7 bytes) |
| sha256 of that record | `c21698334b1e2308b8556ac1d10402342b8d3e837f65fa1c431eb23392824b1d` |
| sha256 of `checksums.txt` | `fec98739daa116991bd0d946e7c90b3d3dd92ec74a5214ad5ac11ea052485fd4` |

This set is **cross-release interoperability, not a second encoder**. zlib
1.2.13 is the same reference implementation this package builds, one release
and four minor versions older: its deflate encoder, its Adler-32 and its
CRC-32 are upstream's own algorithms, and `tests.zig` says so rather than
implying otherwise. What the release gap buys is real, and is what the two
directions of the claim rest on:

* **Inbound.** Every file below is an encoding of `plain.bin` produced by
  zlib 1.2.13. This build is 1.3.2 (`src/zlib.h:44`). Decompressing one proves
  1.3.2 reads what 1.2.13 wrote.
* **Outbound.** The streams `smoke.zig` writes are read back by this build, not
  by 1.2.13 — no 1.2.13 binary is shipped or invoked here — so the outbound
  direction of that claim is asserted by the level and window fields in the
  RFC 1950 wrapper, not by a cross-release run. `consumer/src/main.zig`
  carries the reverse direction instead: a consumer package that resolves this
  module from outside and re-reads the recorded checksums.

| File | Command that produced it | Size | sha256 |
|---|---|---:|---|
| `pyzlib/zlib-n1.z` | `zlib.compress(plain, 1)` | 152 | `86ba4b600c4df6c811c71fc768a1a578da01a08dd6870cb444eaea3a168abb08` |
| `pyzlib/zlib-n6.z` | `zlib.compress(plain, 6)` | 152 | `921cdadb9a6cd09a90495a1de573e73f41b92f7941d1c5b8c9edccba2ddfc217` |
| `pyzlib/zlib-n9.z` | `zlib.compress(plain, 9)` | 152 | `4b6dfdf3838d59eebe005f5cbdfa26b2df37833b4ed1bf504a47235c061b21c9` |
| `pyzlib/raw-n6.bin` | `zlib.compressobj(6, DEFLATED, -15)` | 146 | `695f95c24e3cb7dc7284e4f58dd8a1f519a94fa1aeeb1ab27d5b5afff4a45c46` |
| `pyzlib/raw-n9.bin` | `zlib.compressobj(9, DEFLATED, -15)` | 146 | `695f95c24e3cb7dc7284e4f58dd8a1f519a94fa1aeeb1ab27d5b5afff4a45c46` |

The three `*.z` files are 152 bytes each: a two-byte RFC 1950 wrapper, the
deflate body and the four-byte Adler-32 trailer. The two `raw-*.bin` files are
146 bytes, which is the same body with the wrapper and the trailer removed —
a negative `windowBits`, which is what `src/zlib.h:236-241` describes. Those
six bytes are exactly the difference, and it is the whole reason the raw pair is
in the set.

**The two raw files have the same digest.** That is not a duplicate and not a
copy error: at levels 6 and 9 this 275-byte payload deflate-encodes to the same
146 bytes, because the input is short enough that the match finder finds the
same matches at either effort. Both are recorded, and `check-provenance.sh`
checks both digests, so a later re-generation that made them differ would be
caught as a change to the fixture set rather than silently accepted.

## The recorded checksums

`pyzlib/checksums.txt`, 36 bytes, is zlib 1.2.13's own answer for `plain.bin`:

```
adler32 3970324232
crc32 1368583364
```

Those two integers are stated as literals in three separate places — `tests.zig`
as `recorded_adler32` and `recorded_crc32`, `smoke.zig` as `payload_adler32`
and `payload_crc32`, and `consumer/src/main.zig` as the same pair — and none of
those files computes them from `plain.bin` and compares. The value comes from
here, which is what makes the assertion independent of the code under test: a
facade that returned a wrong Adler-32 would disagree with a file that was
written by a different release of the reference implementation.

`tests.zig:635` checks the same two integers a third way, against the recurrence
written out in `src/doc/rfc1950.txt` and computed in Zig. Three sources, one
answer: the specification, an older release of the reference implementation,
and this build.

## What is deliberately not here

* **No fixture of this build's own output.** A stream produced by
  `compress2` and read back by `uncompress` is a round trip: it proves the two
  halves agree with each other and nothing else. `smoke.zig` and
  `consumer/src/main.zig` both do that as a *supplement*, never as the
  interoperation claim.
* **No hex literal of a compressed stream in a source file.** Every fixture is
  `@embedFile`d, so a 152-byte stream is a diffable file rather than an
  unreadable string constant in `tests.zig`.
* **No `fixtures/rfc/`.** This tree carries the three RFC texts themselves, as
  upstream's own `src/doc/rfc1950.txt`, `rfc1951.txt` and `rfc1952.txt` — which
  `UPSTREAM.sha256` records and `build.zig.zon` `.paths` carries under `src`.
  The RFCs are the *specification* side of the oracle and are read directly out
  of `src/doc/`; they are not duplicated into `fixtures/`, because a second copy
  of a document this repository already vendors byte for byte would be a place
  for the two to drift.

## Re-deriving these fixtures

Each row above names the exact command. To regenerate one, run that command
over the 275 bytes of `plain.bin` with the named producer at the named version,
and compare the new digest with the table. A digest that changes is a fact to
investigate — a different gzip or CPython release, a different `zlib` behind
the module, or a different platform — and never something to re-record to make
the gate pass. An intentional change needs the new producer and version named
here, the new digest, and a numbered `CHANGELOG.md` entry in the same change.

`STATUS`: `SOURCE-CONFIRMED` for every digest, size and command in this file.
Each was computed by reading the bytes in this directory. No producer was run to
produce any of them and no gate was run, so nothing here is a verification
result; the observed runs are recorded in [`README.md`](../README.md) and are
marked `PENDING-VERIFICATION` until the driver observes them.