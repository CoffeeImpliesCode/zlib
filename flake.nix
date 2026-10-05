# Flake interface for the zlib SDK.
#
# Portable counterpart to devenv.nix. Both call ./package.nix, so the package a
# flake builds and the package devenv builds are the same derivation; this file
# only decides which systems are exposed and which variants of that derivation
# they get.
#
# Canonical development is `devenv shell` (see devenv.nix and .envrc). This
# flake exists so the SDK can be built and consumed off this host. `nix develop`
# here is parity, not the canonical entry point, and it deliberately does not
# build the SDK: entering a shell must not require building a library.
#
# flake.lock is not written here: the driver owns locks, and `build.zig.zon`
# `.paths` does not name `flake.lock` because `zig fetch` hashes the paths it
# names and would fail on a name with no file behind it.
#
# SPDX-License-Identifier: zlib
# See FORK-LICENSE.md for what that identifier covers.

{
  description = "zlib 1.3.2, the DEFLATE compression library, packaged for Zig 0.16";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
  };

  outputs = { self, nixpkgs }:
    let
      # These are Unix systems only, which is the same boundary package.nix
      # asserts: it builds for the compiler's native target rather than
      # hand-building a cross triple. zlib itself also has `src/msdos/`,
      # `src/win32/` and `src/os400/` trees upstream, and `build.zig` compiles
      # `x86_64-windows-gnu` in the `check` matrix, but this flake does not
      # claim to package those. Documented in README.md, not worked around here.
      #
      # `wasm32-wasi` is a sixth `check` target for this SDK and is deliberately
      # absent from this list: there is no native Nix target for it that this
      # derivation could be evaluated against without hand-building a triple
      # that has to track nixpkgs, and pretending otherwise would produce a
      # host-architecture library under a foreign name. Its coverage is
      # `zig build check -Dtarget=wasm32-wasi`, not a Nix attribute.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "x86_64-freebsd"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          mk = linkage: pkgs.callPackage ./package.nix {
            inherit linkage;
            zig = pkgs.zig_0_16;
          };
        in
        {
          static = mk "static";

          # A separate variant of the same derivation, not a second SDK.
          # "shared" names the artefact; the flag it passes is Zig's own
          # `-Dlinkage=dynamic`, and what it produces is `libz.so.1.3.2` with
          # the `libz.so.1` soname upstream's own `src/Makefile.in:34-35` names.
          shared = mk "dynamic";

          default = mk "static";
        });

      # Parity only. The canonical development environment is devenv.nix.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.zig_0_16 pkgs.gnumake pkgs.pkg-config ];
        };
      });
    };
}