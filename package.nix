# SPDX-License-Identifier: zlib
# See FORK-LICENSE.md for what that identifier covers, and NOTICE.md for the
# Jean-loup Gailly and Mark Adler terms that cover everything in src/.

{ lib
, stdenv
, zig
, patchelf
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "" "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"\", \"static\" or \"dynamic\", not ${toString linkage}";

src = lib.cleanSourceWith {
  src = ./.;
  filter = path: _type:
    let name = builtins.baseNameOf (toString path); in
    !(lib.elem name [
      ".git"
      ".direnv"
      ".devenv"
      ".zig-cache"
      "zig-cache"
      "zig-pkg"
      "zig-out"
      "result"
    ]);
};

# patchelf cannot process Mach-O binaries.
isElfTarget = !stdenv.hostPlatform.isDarwin;
in

# Restrict Nix builds to native targets; cross-target checks use Zig and cross-test.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "zlib";
  version = "1.3.2";

  inherit src;

  strictDeps = true;
  dontPatch = true;

  # The install phase below runs the only Zig build.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # The C library is the only propagated dependency.

  propagatedBuildInputs = [ stdenv.cc.libc ];
  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Keep Zig caches outside the unpacked source tree.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dcpu=baseline \
      ${lib.optionalString (requestedLinkage != "") "-Dlinkage=${requestedLinkage}"}

    # Remove Zig's TMPDIR build-cache entries from installed ELF rpaths.
    # Resolve symlinks first so soname links still point to the patched object.
    ${lib.optionalString isElfTarget ''
      for elf in "$out"/bin/* "$out"/lib/*.so*; do
        [ -f "$elf" ] || continue
        elf=$(readlink -f "$elf")
        rpath=$(patchelf --print-rpath "$elf") || rpath=""
        kept=""
        rest=$rpath
        while [ -n "$rest" ]; do
          entry="''${rest%%:*}"
          case "$entry" in
            "$TMPDIR"/*) ;;
            *) if [ -z "$kept" ]; then kept=$entry; else kept=$kept:$entry; fi ;;
          esac
          if [ "$entry" = "$rest" ]; then rest=""; else rest="''${rest#*:}"; fi
        done
        [ "$kept" = "$rpath" ] || patchelf --set-rpath "$kept" "$elf"
      done
    ''}

    runHook postInstall
  '';

  enableParallelBuilding = true;

  meta = {
    description = "zlib 1.3.2, the general-purpose DEFLATE compression library, built from the official release sources";
    longDescription = ''
      The complete zlib 1.3.2 release source -- the deflate and inflate
      compressor and decompressor, the Adler-32 and CRC-32 checksums, the
      zlibWrapper-free gzip file-access layer and every retained contributed
      and platform tree -- compiled from the tarball's own src/ directory with
      Zig, with no configure, no autotools, no CMake and no build-time
      download. Ships the library, both public headers, the manual page, a
      pkg-config file, and both of zlib's notices.
    '';
    license = lib.licenses.zlib;
    platforms = lib.platforms.unix;
  };
}
