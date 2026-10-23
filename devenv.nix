# SPDX-License-Identifier: zlib

{ pkgs, ... }:

let
  zig = pkgs.zig_0_17;

  zlib = linkage: pkgs.callPackage ./package.nix {
    inherit linkage;
    zig = zig;
  };

  # Use the checkout path without copying it into the Nix store.
  sdk_root = builtins.toString ./.;

  # Prefer caller cache directories, then XDG_CACHE_HOME or TMPDIR.
  zig_caches = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/zlib/zig-local-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zlib/zig-local-cache"
      fi
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/zlib/zig-global-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zlib/zig-global-cache"
      fi
    fi
    if [ -n "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_LOCAL_CACHE_DIR"
    fi
    if [ -n "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    fi
  '';

  # Tasks require an external cache directory.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "zlib devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # Tasks run from the caller's directory; switch to this checkout first.
  in_sdk = ''
    ${zig_caches}
    ${require_external_output}
    cd "${sdk_root}" || exit 1
  '';

  native_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native" "''$@"
  '';

  consumer_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/consumer" "''$@"
  '';
in
{
  packages = [
    zig
    pkgs.gnumake
    pkgs.pkg-config
  ];

  assertions = [
    {
      assertion = zig.version == "0.17.0";
      message = "The zlib SDK requires Zig 0.17.0; nixpkgs resolved zig_0_17 to ${zig.version}";
    }
  ];

  # Interactive shells use the same cache setup as tasks.
  enterShell = ''
    ${zig_caches}
  '';

  outputs.static = zlib "static";
  outputs.shared = zlib "dynamic";
  outputs.default = zlib "static";

  tasks = {
    "sdk:build" = {
      description = ''
        Compile the native library and install the delivery tree (library, both
        public headers, the manual page, zlib.pc and the licence records) under
        the external cache rather than in this checkout.
      '';
      exec = ''
        ${in_sdk}
        zig build --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/static" ${native_flags}
      '';
    };

    "sdk:build:shared" = {
      description = ''
        Compile the native library as a shared object -- libz.so.1.3.2 with the
        libz.so.1 soname, upstream's own file names -- and install it under its
        own external prefix.
      '';
      exec = ''
        ${in_sdk}
        zig build -Dlinkage=dynamic --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic" ${native_flags}
      '';
    };

    "sdk:test" = {
      description = "Run the behavioural tests";
      exec = ''
        ${in_sdk}
        zig build test ${native_flags}
      '';
    };

    "sdk:test:release-safe" = {
      description = "Run the behavioural tests in ReleaseSafe";
      exec = ''
        ${in_sdk}
        zig build test -Doptimize=ReleaseSafe ${native_flags}
      '';
    };

    "sdk:smoke" = {
      description = "Run the deterministic example";
      exec = ''
        ${in_sdk}
        zig build smoke ${native_flags}
      '';
    };

    "sdk:check" = {
      description = ''
        Compile the 15-unit closure, the facade, the tests and the example for
        each of the six workspace check targets without running any of them
      '';
      exec = ''
        ${in_sdk}
        zig build check ${native_flags}
      '';
    };

    "sdk:check:shared" = {
      description = "The same six-target compile check against the shared object";
      exec = ''
        ${in_sdk}
        zig build check -Dlinkage=dynamic ${native_flags}
      '';
    };

    "sdk:consumer" = {
      description = "Build and run the separate consumer package against this SDK";
      exec = ''
        ${in_sdk}
        cd consumer
        zig build run ${consumer_flags}
      '';
    };

    "sdk:provenance" = {
      description = ''
        Check the 254 recorded upstream digests, the exact native file set, the
        12 fixture digests, the preserved upstream README bytes and zlib's own
        notice in both of the files that carry it. This is a source-integrity
        check, not a build gate.
      '';
      exec = ''
        ${in_sdk}
        bash tools/check-provenance.sh
      '';
    };

    "sdk:runtime:shared-provider" = {
      description = ''
        Build the shared object and keep it at a known path under the external
        cache, for the two runtime-loading tasks below to load
      '';
      exec = ''
        ${in_sdk}
        zig build -Dlinkage=dynamic --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic" ${native_flags}
      '';
    };

    "sdk:runtime:test" = {
      description = ''
        Run the behavioural tests through the runtime dispatch, loading the
        provider built by sdk:runtime:shared-provider
      '';
      exec = ''
        ${in_sdk}
        zig build test -Druntime=true ${native_flags} -- --provider "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic/lib/libz.so.1.3.2"
      '';
    };

    "sdk:runtime:smoke" = {
      description = "Run the deterministic example through the runtime dispatch";
      exec = ''
        ${in_sdk}
        zig build smoke -Druntime=true ${native_flags} -- --provider "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic/lib/libz.so.1.3.2"
      '';
    };

    # Package tasks use the caller's devenv project and store outputs in Nix.
    "sdk:package:static" = {
      description = ''
        Build the static Nix variant through devenv's own lazy output. No lock
        is needed by this path; `devenv build outputs.static` resolves the
        pinned input from devenv.lock, which the driver owns.
      '';
      exec = "devenv build outputs.static";
    };

    "sdk:package:shared" = {
      description = "Build the shared Nix variant through devenv's own lazy output";
      exec = "devenv build outputs.shared";
    };
  };
}
