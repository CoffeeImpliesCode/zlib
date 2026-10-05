/* The one header this package translates.
 *
 * `zig build` runs translate-c over this file, and what that translation
 * becomes is the `c` module the Zig facade in zig/root.zig imports.  Its whole
 * job is to name the public headers of the library this build compiles.
 *
 * Which headers those are
 * -----------------------
 * zlib installs two headers, and `src/Makefile.in:343-347` is upstream's own
 * install rule for them:
 *
 *   install: install-libs
 *        -@if [ ! -d $(DESTDIR)$(includedir) ]; then mkdir -p ...; fi
 *        rm -f $(DESTDIR)$(includedir)/zlib.h $(DESTDIR)$(includedir)/zconf.h
 *        cp $(SRCDIR)zlib.h zconf.h $(DESTDIR)$(includedir)
 *
 * so this file names both:
 *
 *   zlib.h    the public API.  Every entry point this SDK's facade wraps is
 *             declared here, and so is every constant it quotes.
 *   zconf.h   the configuration header.  It declares nothing - it is all
 *             `#define`s and typedefs - but it decides the numeric ABI
 *             (`uInt`, `uLong`, `z_off_t`, `z_size_t`, `Bytef`), the export
 *             decoration (`ZEXTERN`, `ZEXPORT`, `FAR`) and which optional
 *             system declarations zlib's own sources see.
 *
 * Both are included whole, with their own include guards, so this wrapper
 * cannot disagree with the real headers by omission and cannot re-declare a
 * typedef with a different width.
 *
 * Why zconf.h is listed even though zlib.h already includes it
 * ------------------------------------------------------------
 * `src/zlib.h:33-38` includes `zconf.h` by bare name - `#include <zconf.h>`
 * when `ZLIB_BUILD` is defined, `#include "zconf.h"` otherwise - so naming
 * zlib.h alone would reach it.  The second include is named here anyway for
 * two reasons that are both about making the two installation routes agree:
 *
 *   * It is one of the two headers `make install` puts in `include/`, so a
 *     translation that names exactly the installed set cannot describe more
 *     than a C consumer would.
 *   * `zconf.h` is the header this package *generates per target* (see below),
 *     and it is the reason the generated directory has to be on this
 *     translation's include line and not only the library's.  `src/zconf.h:488`
 *     reaches `#include <unistd.h>` only when `Z_HAVE_UNISTD_H` is defined,
 *     and that macro is defined at `src/zconf.h:446-448` - the line
 *     `tools/genzconf.c` rewrites.  A translation that read the *unconfigured*
 *     `src/zconf.h` would take the `-0` branch and see a smaller header than
 *     the compiled C did.
 *
 * The generated zconf.h, not the one in the tarball
 * --------------------------------------------------
 * SOURCE-CONFIRMED: the 1.3.2 tarball ships `src/zconf.h` byte-identical to
 * `src/zconf.h.in` - both are sha256
 * cb7c2c84211473b4699223edd363d3207b43b9578e739b5bf638f42204ea6e0f - so the
 * header in the tree is the *unconfigured template*, with `#if HAVE_UNISTD_H-0`
 * at `:446` and `#if HAVE_STDARG_H-0` at `:450` still switched off.  Upstream
 * configures it (`src/configure:643-672`); this build reproduces exactly those
 * two rewrites in `tools/genzconf.c`, from answers `build.zig` computes out of
 * `std.Target` rather than out of the host, and puts the result on this
 * translation's include line ahead of `src/`.  That is why `src/zconf.h` is
 * *not* excluded here: the generated header must be found by the bare
 * `#include "zconf.h"` at `src/zlib.h:37` *before* the unconfigured one.
 *
 * What is deliberately not here
 * -----------------------------
 * A copy of any declaration, and no macro of this build's own.
 *
 * zlib's configuration macros are on the compile line, not here, and not in the
 * header, because they describe *this* build rather than what the interface is.
 * There are none of them on a POSIX target: `src/configure` adds a `-D` only
 * for a probe that failed (`NO_FSEEKO`, `NO_STRERROR`, `NO_SIZE_T`,
 * `_LFS64_LARGEFILE`, `src/configure:586-622`), and every one of those probes
 * succeeds on a platform with a `size_t`, large-file support and `strerror`.
 * The two that would change the interface - `ZLIB_CONST`
 * (`src/configure:264-270`, reachable only through `--const`) and `Z_PREFIX`
 * (`src/zconf.h:17-18`, reachable only through `--zprefix`) - are options
 * rather than defaults, and this build asks for neither.  `Z_SOLO`, which
 * `src/configure:684-692` would bake into the header to drop the `gz*` half
 * entirely, is likewise not requested: `zig build` compiles `OBJC` in full
 * (`src/Makefile.in:59-71`) and installs the `gz*` API.
 *
 * `Z_PREFIX` is worth one more sentence because it is the one that would
 * change what *this* file means: with it set, `src/zconf.h:26-38` renames
 * `adler32` to `z_adler32`, `compress2` to `z_compress2` and so on, and the
 * translation would describe a library with no `deflate` at all.  Leaving it
 * off is what makes `dep.artifact("zlib")` export the names a C consumer
 * expects.
 */

#ifndef ZLIB_TRANSLATE_H
#define ZLIB_TRANSLATE_H

#include <zlib.h>
#include <zconf.h>

#endif /* ZLIB_TRANSLATE_H */