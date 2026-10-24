# Changelog

- Pass the source-length pointer to `uncompress2` during runtime provider validation, fixing loads with static or shared artifact linkage.
- Split runtime symbol lists on commas and ASCII whitespace; add search-prefix library directories to system-header translation for static and shared linkage.
- Share runtime header modules, compile runtime tests/smoke/consumer in `check`, and bind system consumers to installed `libzlib` with forwarded search prefixes and matching pkg-config metadata.
- Exclude targets without a dynamic loader from default shared-linkage and runtime-loading checks, allowing native shared builds and provider installs.

## 2026-10-23

- Port to Zig 0.17.0.
- Parent `consumer` uses its own cache/prefix defaults and installs cross-target executables requiring external executors.

## 2026-10-05

- Added upstream copyright and licence text to `README.md`.
- Added a zlib 1.3.2 package for Zig 0.16.0 with static and shared `libz` artifacts.
- Added target-specific `zconf.h` generation and installation of headers, pkg-config metadata, the man page, and licence records.
- Added a typed Zig module for compression, checksums, streams, gzip headers, and `gz*` file APIs.
- Added runtime-loaded mode (`-Druntime=true`) and system-library mode (`-Dsystem=true`).
- Corrected the `wasm32-wasi` target ABI selection.
