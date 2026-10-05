// SPDX-License-Identifier: zlib
// See ../FORK-LICENSE.md for what that identifier covers.
//
// This header is spelled with line comments rather than one block comment on
// purpose. It quotes the comment markers of `src/zconf.h.in` verbatim, and a
// quoted `/*` closes a block comment in every C compiler - the `*/` on
// genzconf.c:15 used to end this comment and turn the rest of it into code, so
// the file did not compile with GCC, with Clang or with Zig's own C frontend.
// A `//` comment is the only comment form that can hold a literal `/*`.
//
// genzconf -- turn the zlib 1.3.2 `zconf.h.in` template into the configured
// `zconf.h` that this build compiles against.
//
// ## Why this program exists
//
// SOURCE-CONFIRMED: the 1.3.2 tarball ships `zconf.h` byte-identical to
// `zconf.h.in` -- both are sha256
// cb7c2c84211473b4699223edd363d3207b43b9578e739b5bf638f42204ea6e0f -- so the
// header the tarball contains is the *unconfigured template*. Two lines in it
// are still switched off:
//
//   src/zconf.h.in:446  #if HAVE_UNISTD_H-0     /* may be set to #if 1 by ./configure */
//   src/zconf.h.in:450  #if HAVE_STDARG_H-0     /* may be set to #if 1 by ./configure */
//
// `#if HAVE_UNISTD_H-0` evaluates false -- the `-0` suffix is upstream's own
// "this probe has not run" spelling -- so neither `Z_HAVE_UNISTD_H` nor
// `Z_HAVE_STDARG_H` is defined, and `src/zconf.h.in:488-490` therefore never
// reaches `#include <unistd.h>`. Upstream's answer is `src/configure`, which
// copies the template and rewrites it:
//
//   src/configure:643   cp -p ${SRCDIR}zconf.h.in zconf.h
//   src/configure:653   sed < zconf.h "/^#if HAVE_UNISTD_H-0.* may be/s/ HAVE_UNISTD_H-0\(.*\) may be/ 1\1 was/" > zconf.temp.h
//   src/configure:668   sed < zconf.h "/^#if HAVE_STDARG_H-0.* may be/s/ HAVE_STDARG_H-0\(.*\) may be/ 1\1 was/" > zconf.temp.h
//
// and two more rewrites this build asks for neither of:
//
//   src/configure:677   sed < zconf.h "/#ifdef Z_PREFIX.* may be/s/def Z_PREFIX\(.*\) may be/ 1\1 was/" > zconf.temp.h
//                       -- requestable with --zprefix
//   src/configure:685   sed '/#define ZCONF_H/a\
//                       #define Z_SOLO
//
//                       ' < zconf.h > zconf.temp.h
//                       -- requestable with --solo
//
// ## The acceptance criterion
//
// OBSERVED, by running exactly the two `sed` expressions above over the
// vendored `src/zconf.h.in`: each rewrite turns
//
//   #if HAVE_UNISTD_H-0     /* may be set to #if 1 by ./configure */
//
// into
//
//   #if 1     /* was set to #if 1 by ./configure */
//
// and nothing else in the file changes. The configured header for both probes
// succeeding is sha256
// 0718a11beb3295b345fb29a63b44b654b282d82c4cd0513f6225587f2b29b8bb.
//
// That digest is this program's acceptance criterion, and
// `tools/check-provenance.sh` is what checks it: the script builds this
// generator with the host C compiler, runs it over `src/zconf.h.in` with both
// probes requested, and compares the digest against the line recorded in
// `UPSTREAM.md`. That is a real, runnable check, and it is a check *for the
// driver to run* -- this package claims no result from it.
//
// The algorithm below was compared against the `sed` path before this file
// was written: the same steps were applied to the same input and the two
// outputs hashed identically. See "How the sed expression maps onto this
// code".
//
// ## How the sed expression maps onto this code
//
// A GNU sed address `/A.* may be/` and a substitution `/P\(.*\) may be/` do
// three things that are easy to get subtly wrong, so they are spelled out
// once here and implemented once, in `apply_rule`.
//
//   * The address is anchored at the *start* of the line, and its `.*` is
//     greedy and backtracks, so the address is satisfied if *any* ` may be`
//     follows the anchor.
//   * The substitution is searched from the left of the pattern space, so `P`
//     matches at its *first* occurrence on the line -- which is not where the
//     address's anchor ends. For the two probes the substituted pattern is
//     ` HAVE_UNISTD_H-0`, with a leading space, so it starts one byte
//     *before* the `H` of the anchor; for `--zprefix` it is
//     `def Z_PREFIX`, which starts inside `#ifdef`.
//   * The capture group `\(.*\)` is greedy, so it runs to the *last* ` may be`
//     on the line, not the first.
//
// So for one rule: let `m` be the first occurrence of the substituted pattern
// on the line, and `k` the last occurrence of ` may be`. The matched region is
// `[m, k + len(tail))`, the capture is `line[m + len(pattern) .. k)`, and the
// replacement is `" 1" ++ capture ++ " was"`.
//
// ## What this program does not do
//
// It does not probe anything. It is a host program, and a host program's
// `#include <unistd.h>` is a statement about the machine that built it, not
// about the machine the library is being compiled for. `build.zig` computes the
// two answers from `std.Target` and passes them in, so a cross build gets a
// `zconf.h` that answers for the target. That is the whole reason this file
// is a program and not a one-liner in the build graph: the rewrite is trivial and
// the *input* is not.
//
// ## Usage
//
//   genzconf <input> <output> <have_unistd:0|1> <have_stdarg:0|1>
//            [--zprefix] [--solo]
//
// The output is written to a sibling temporary and renamed into place, so a
// failed run cannot leave a truncated `zconf.h` on the include line of every
// translation unit in the build.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

/* One upstream `sed` expression, as the three pieces its syntax actually
 * has. `addr` is the `/A.* may be/` anchor, `pattern` is the `P` of the
 * `/P\(.*\) may be/` substitution, and `tail` is the literal ` may be` the
 * two share. Keeping them apart is the point: for the two probes `pattern` is
 * the anchor minus its last byte. */
struct rule {
    const char *name;
    const char *addr;
    const char *pattern;
    const char *tail;
};

/* src/configure:653 */
static const struct rule rule_unistd = {
    "HAVE_UNISTD_H", "#if HAVE_UNISTD_H-0", " HAVE_UNISTD_H-0", " may be"
};

/* src/configure:668 */
static const struct rule rule_stdarg = {
    "HAVE_STDARG_H", "#if HAVE_STDARG_H-0", " HAVE_STDARG_H-0", " may be"
};

/* src/configure:677 -- only applied with --zprefix. Upstream's address is
 * `/#ifdef Z_PREFIX.* may be/` and its substitution is
 * `/def Z_PREFIX\(.*\) may be/`: the two do not start at the same byte, which
 * is why `addr` and `pattern` are separate fields here. */
static const struct rule rule_zprefix = {
    "Z_PREFIX", "#ifdef Z_PREFIX", "def Z_PREFIX", " may be"
};

/* src/configure:685 -- the `/#define ZCONF_H/a\` rewrite. It appends after the
 * anchored line rather than replacing inside it, so it is not a `rule`.
 *
 * The insertion text is one line, not the two the script at
 * `src/configure:685-689` appears to spell: GNU sed's backslash form of `a`
 * takes exactly one text line, so the blank line that follows
 * `#define Z_SOLO` in the script is an empty command and appends nothing.
 * OBSERVED against the system sed, on `#define ZCONF_H\n\nX\n`:
 *
 *     #define ZCONF_H
 *     #define Z_SOLO
 *     <the template's own blank line>
 *     X
 */
static const char solo_anchor[] = "#define ZCONF_H";
static const char solo_text[] = "#define Z_SOLO\n";

static void fail(const char *what, const char *path)
{
    fprintf(stderr, "genzconf: %s in %s\n", what, path);
    exit(2);
}

/* The index of the first occurrence of `needle` in `line[0..len)`, or
 * `(size_t)-1`. */
static size_t find_first(const char *line, size_t len, const char *needle,
                         size_t needle_len)
{
    size_t i;
    if (needle_len > len)
        return (size_t)-1;
    for (i = 0; i + needle_len <= len; i++)
        if (memcmp(line + i, needle, needle_len) == 0)
            return i;
    return (size_t)-1;
}

/* The index of the last occurrence of `needle` in `line[0..len)`, or
 * `(size_t)-1`. */
static size_t find_last(const char *line, size_t len, const char *needle,
                        size_t needle_len)
{
    size_t i;
    if (needle_len > len)
        return (size_t)-1;
    for (i = len - needle_len + 1; i > 0; i--)
        if (memcmp(line + i - 1, needle, needle_len) == 0)
            return i - 1;
    return (size_t)-1;
}

/* Grow `*buf` to hold at least `need` bytes plus a terminator, keeping what it
 * already holds. `*cap` is the buffer's capacity; the line's length is the
 * caller's business and is never passed here. */
static void reserve(char **buf, size_t *cap, size_t need)
{
    char *grown;
    size_t want = need + 1;
    if (*cap >= want)
        return;
    while (*cap < want)
        *cap = *cap ? *cap * 2 : 256;
    grown = (char *)realloc(*buf, *cap);
    if (grown == NULL)
        fail("out of memory", "<line buffer>");
    *buf = grown;
}

/* Apply one rule to one line, in place, rewriting `*len`.
 *
 * Returns 1 when the rule matched and the line was rewritten, 0 when it did
 * not. The line keeps its trailing newline throughout, so `*len` stays the
 * exact byte count to write.
 */
static int apply_rule(const struct rule *rule, char **line, size_t *cap,
                      size_t *len)
{
    size_t addr_len = strlen(rule->addr);
    size_t pat_len = strlen(rule->pattern);
    size_t tail_len = strlen(rule->tail);
    size_t m;
    size_t k;
    size_t capture;
    size_t before;
    size_t after;
    size_t out;

    if (*len < addr_len || memcmp(*line, rule->addr, addr_len) != 0)
        return 0;

    /* `m`: the first occurrence of the substituted pattern. */
    m = find_first(*line, *len, rule->pattern, pat_len);
    if (m == (size_t)-1)
        return 0;

    /* `k`: the last occurrence of the tail. A `k` at or before the end of the
     * pattern means sed's `\(.*\)` could not have matched here. */
    k = find_last(*line, *len, rule->tail, tail_len);
    if (k == (size_t)-1 || k < m + pat_len)
        return 0;

    capture = k - (m + pat_len);
    before = m;
    after = *len - (k + tail_len);

    /* `" 1" ++ capture ++ " was"`, the replacement `src/configure` spells
     * ` 1\1 was`. The result is
     *
     *     line[0 .. m) ++ " 1" ++ line[m + pat_len .. k) ++ " was" ++ line[k + tail_len .. *len)
     *
     * so the capture has to travel left by `pat_len - 2` -- the width of the
     * substituted pattern minus the width of the `" 1"` now in front of it --
     * and the tail has to travel right past the widened replacement. Writing
     * `" was"` at `before + 2 + capture` without moving the capture first put
     * it `pat_len - 2` bytes early, on top of the capture's own tail, and
     * produced `#if 1AVE_UNI was set to ...` instead of `#if 1     /* was set
     * to ...`.
     */
    out = before + 2 + capture + 4 + after;
    reserve(line, cap, out);
    /* The capture first, because its destination is where the tail's move
     * begins. */
    memmove(*line + before + 2, *line + before + pat_len, capture);
    memmove(*line + before + 2 + capture + 4, *line + k + tail_len, after);
    memcpy(*line + before, " 1", 2);
    memcpy(*line + before + 2 + capture, " was", 4);
    *len = out;
    return 1;
}

int main(int argc, char **argv)
{
    const char *input;
    const char *output;
    char *temp;
    size_t temp_len;
    int have_unistd;
    int have_stdarg;
    int want_zprefix = 0;
    int want_solo = 0;
    /* Whether each rewrite actually ran. A request that did not match is a
     * failure this program reports, never a line it silently skips; and a rule
     * can only set its flag from inside its own `if (have_* / want_*)` guard,
     * so an unrequested rewrite is proven not to have run. */
    int done_unistd = 0;
    int done_stdarg = 0;
    int done_zprefix = 0;
    int done_solo = 0;
    FILE *in;
    FILE *out;
    char *line = NULL;
    size_t cap = 0;
    size_t len;
    ssize_t got;
    int i;
    int status = 0;

    if (argc < 5) {
        fprintf(stderr,
                "usage: genzconf <input> <output> <have_unistd:0|1> "
                "<have_stdarg:0|1> [--zprefix] [--solo]\n");
        return 2;
    }
    input = argv[1];
    output = argv[2];
    have_unistd = (atoi(argv[3]) == 1);
    have_stdarg = (atoi(argv[4]) == 1);

    for (i = 5; i < argc; i++) {
        if (strcmp(argv[i], "--zprefix") == 0) {
            want_zprefix = 1;
        } else if (strcmp(argv[i], "--solo") == 0) {
            want_solo = 1;
        } else {
            fprintf(stderr, "genzconf: unknown option '%s'\n", argv[i]);
            return 2;
        }
    }

    temp_len = strlen(output) + 8;
    temp = (char *)malloc(temp_len);
    if (temp == NULL)
        fail("out of memory", output);
    strcpy(temp, output);
    strcat(temp, ".tmp");

    in = fopen(input, "rb");
    if (in == NULL)
        fail("cannot open the input template", input);
    out = fopen(temp, "wb");
    if (out == NULL)
        fail("cannot create", temp);

    /* `have_unistd` and `have_stdarg` are the answers `build.zig` computed from
     * `std.Target` for the target being built, never from the host. A false
     * answer means the probe would fail for that target, and upstream's own
     * `else` branch (`src/configure:655-657`) leaves the template line alone in
     * that case -- which is why each rewrite is guarded by its answer rather
     * than applied unconditionally. */
    while ((got = getline(&line, &cap, in)) != -1) {
        len = (size_t)got;

        if (have_unistd && !done_unistd)
            done_unistd = apply_rule(&rule_unistd, &line, &cap, &len);
        if (have_stdarg && !done_stdarg)
            done_stdarg = apply_rule(&rule_stdarg, &line, &cap, &len);
        if (want_zprefix && !done_zprefix)
            done_zprefix = apply_rule(&rule_zprefix, &line, &cap, &len);

        if (want_solo && !done_solo) {
            size_t anchor_len = strlen(solo_anchor);
            /* The sed address `/#define ZCONF_H/a\` matches a line *starting*
             * with that text, which would also match a hypothetical
             * `#define ZCONF_H_SOMETHING_ELSE`. Requiring the anchor to end
             * the line, or to be followed only by blank space, keeps this to
             * the one line upstream means -- and `zconf.h.in:9` is
             * `#define ZCONF_H` alone. */
            int anchored =
                len >= anchor_len &&
                memcmp(line, solo_anchor, anchor_len) == 0 &&
                (len == anchor_len || line[anchor_len] == '\n' ||
                 line[anchor_len] == '\r' || line[anchor_len] == ' ' ||
                 line[anchor_len] == '\t');
            if (anchored) {
                size_t extra = strlen(solo_text);
                /* sed's `a\` appends *after* the addressed line, so the
                 * insertion point is one byte past that line's own newline,
                 * not the end of its text: `#define ZCONF_H\n` becomes
                 * `#define ZCONF_H\n#define Z_SOLO\n\n`. */
                /* One byte past the line, which is past its own newline too:
                 * stopping one byte short of `len` to skip that newline put
                 * the insertion *before* it and produced
                 * `#define ZCONF_H#define Z_SOLO` on one line. */
                size_t at = len;
                reserve(&line, &cap, len + extra);
                memmove(line + at + extra, line + at, len - at);
                memcpy(line + at, solo_text, extra);
                len += extra;
                done_solo = 1;
            }
        }

        /* `len`, not the `got` `getline` returned: the rewrites above have
         * already changed the line, shrinking it by three bytes per probe
         * (` may be` -> ` was`) and growing it under `--solo`. */
        if (fwrite(line, 1, len, out) != len)
            fail("write error on", temp);
    }

    free(line);
    if (ferror(in))
        fail("read error on", input);
    if (fclose(out) != 0)
        fail("cannot close", temp);
    fclose(in);

    /* Every rewrite that was requested has to have found its line. */
    if (have_unistd && !done_unistd) {
        fprintf(stderr,
                "genzconf: %s has no line starting '%s', so the HAVE_UNISTD_H "
                "probe build.zig asked for could not be applied; this does not "
                "look like zlib 1.3.2's zconf.h.in\n",
                input, rule_unistd.addr);
        status = 1;
    }
    if (have_stdarg && !done_stdarg) {
        fprintf(stderr,
                "genzconf: %s has no line starting '%s', so the HAVE_STDARG_H "
                "probe build.zig asked for could not be applied; this does not "
                "look like zlib 1.3.2's zconf.h.in\n",
                input, rule_stdarg.addr);
        status = 1;
    }
    if (want_zprefix && !done_zprefix) {
        fprintf(stderr,
                "genzconf: %s has no line starting '%s', so --zprefix could "
                "not be applied\n",
                input, rule_zprefix.addr);
        status = 1;
    }
    if (want_solo && !done_solo) {
        fprintf(stderr,
                "genzconf: %s has no line starting '%s', so --solo could not "
                "be applied\n",
                input, solo_anchor);
        status = 1;
    }

    if (status != 0) {
        remove(temp);
        free(temp);
        return status;
    }

    if (rename(temp, output) != 0) {
        fprintf(stderr, "genzconf: cannot rename %s to %s\n", temp, output);
        free(temp);
        return 1;
    }
    free(temp);
    return 0;
}