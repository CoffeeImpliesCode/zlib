# Changelog

## 2026-10-05

- Added upstream copyright and licence text to `README.md`.
- Added a zlib 1.3.2 package for Zig 0.16.0 with static and shared `libz` artifacts.
- Added target-specific `zconf.h` generation and installation of headers, pkg-config metadata, the man page, and licence records.
- Added a typed Zig module for compression, checksums, streams, gzip headers, and `gz*` file APIs.
- Added runtime-loaded mode (`-Druntime=true`) and system-library mode (`-Dsystem=true`).
- Corrected the `wasm32-wasi` target ABI selection.
