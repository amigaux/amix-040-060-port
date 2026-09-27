#!/usr/bin/env python3
"""spl-gate.py -- G1/G2 for one kernel translation unit compiled under -traditional (2026-09-28).

WHY.  Under -traditional gcc does not define __STDC__, so the stock <sys/types.h> takes its
non-ANSI branch and defines `volatile` (and `const`) as nothing.  <sys/inline.h>'s spl()/splx()
are asms with an output; stripped of `volatile`, gcc deletes every one whose output is unused --
splx() always, and an spl6() whose value only feeds a dead splx() -- so a driver's critical
sections compile to no mask at all.  The same erasure turns every `volatile` MMIO access into an
ordinary load that may be narrowed, merged or hoisted.  The toolchain now passes
-Dvolatile=__volatile__ -Dconst=__const__ (gcc-cross-amix 7a1d727); these two gates make sure
every C object linked into this kernel was built that way and kept its masks:

  G1 (cause)   `cc CFLAGS -dM -E unit.c` must not define `volatile` EMPTY.
  G2 (effect)  every FUNCTION whose preprocessed body calls _spl[0-7]/splx (or one of the unit's
               own spl macros, counted in the raw source, since a macro that expands to an asm or
               to nothing leaves no name behind) must carry at least one `,%sr` write in
               `objdump -d`.  Per function, not by count: gcc merges tail exits, so a function
               with three splx() sites can carry one SR write.  A function with sites and no
               symbol in the object fails.  A unit with an --allow note reports instead of failing.

The semantics are the amix-kerntools k0-gates.py `spl` gate's, deliberately: the same regexes,
the same function splitter, the same rules, so a unit judged here and there gets one verdict.
This copy exists because this repository has to build on its own.

usage: spl-gate.py --object O.o --source unit.c --cflags "$CF" [--cc CC] [--cwd DIR]
                   [--macro NAME ...] [--allow NOTE] [--label NAME] [extra cc args after --]
Exit 0 = both gates pass (or G2 allowlisted); 1 = a gate failed or could not run.
"""
import argparse, os, re, shlex, subprocess, sys

SPL_CALL_RE = re.compile(r"\b_?spl(?:[0-7]|x|tty|hi|lo|clock|imp|net|bio|str)\s*\(")
SR_WRITE_RE = re.compile(r",%sr\b")
FUNC_LABEL_RE = re.compile(r"^[0-9a-f]+ <([^>+]+)>:")
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
OBJDUMP = "m68k-linux-gnu-objdump"


def strip_c(text):
    """Comments and string/char literals blanked (lengths kept), so braces and parens inside
    them do not count."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(" " * (j - i)); i = j
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(c + " " * (j - i - 2) + c if j - i >= 2 else c); i = j
        else:
            out.append(c); i += 1
    return "".join(out)


def split_functions(text):
    """[(name, body)] for every top-level function definition in C text (K&R or ANSI heads).
    A `{` at depth 0 opens a function when an identifier followed by `(` was seen since the
    last top-level statement end; struct/enum/initializer blocks have no such head and are
    skipped.  K&R parameter declarations between `)` and `{` end with `;` and must not reset
    the head, so a top-level `;` resets only when the pending head carries an `=`."""
    t = strip_c(text)
    funcs, depth, i, n = [], 0, 0, len(t)
    head_start, name, body_start = 0, None, None
    while i < n:
        c = t[i]
        if depth == 0:
            if c == "(":
                m = list(IDENT_RE.finditer(t, head_start, i))
                if m and t[m[-1].end():i].strip() == "":
                    name = m[-1].group(0)
            elif c == ";":
                if name is None or "=" in t[head_start:i]:
                    name, head_start = None, i + 1
            elif c == "{":
                depth = 1; body_start = i + 1
            elif c == "}":
                name, head_start = None, i + 1
        else:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    if name:
                        funcs.append((name, t[body_start:i]))
                    name, head_start = None, i + 1
        i += 1
    return funcs


def spl_sites(body, macros=()):
    """Number of spl call sites in a function body: the kernel names, plus the unit's own
    macro names (raw-source scan; a no-op macro vanishes from the preprocessed text)."""
    n = len(SPL_CALL_RE.findall(body))
    for mname in macros:
        if SPL_CALL_RE.match(mname + "("):
            continue                            # a kernel name (e.g. splx): counted above already
        n += len(re.findall(r"\b%s\s*\(" % re.escape(mname), body))
    return n


def sr_writes_by_function(listing):
    """{function: count of `,%sr` writes} from an `objdump -d` listing."""
    out, cur = {}, None
    for ln in listing.splitlines():
        m = FUNC_LABEL_RE.match(ln)
        if m:
            cur = m.group(1); out.setdefault(cur, 0)
        elif cur and SR_WRITE_RE.search(ln):
            out[cur] += 1
    return out


def g1_erases_volatile(dm_text):
    """True when the macro dump defines `volatile` as nothing."""
    return any(re.match(r"^#define volatile\s*$", ln) for ln in dm_text.splitlines())


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--object", required=True)
    ap.add_argument("--source", required=True)
    ap.add_argument("--cflags", required=True, help="the compile's flags, as one string")
    ap.add_argument("--cc", default="m68k-cbm-sysv4-gcc")
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--macro", action="append", default=[])
    ap.add_argument("--allow", default=None)
    ap.add_argument("--label", default=None)
    ap.add_argument("extra", nargs="*", help="further compile arguments (-I, -D), after --")
    a = ap.parse_args()
    label = a.label or os.path.basename(a.object)
    base = shlex.split(a.cc) + shlex.split(a.cflags) + a.extra
    failed = False

    def ok(msg): print("      [OK]   %s: %s" % (label, msg))
    def note(msg): print("      [--]   %s: %s" % (label, msg))
    def fail(msg):
        nonlocal failed
        failed = True
        print("      [FAIL] %s: %s" % (label, msg))

    # G1
    r = subprocess.run(base + ["-dM", "-E", a.source], capture_output=True, text=True, cwd=a.cwd)
    if r.returncode != 0:
        fail("G1 preprocess failed: %s" % r.stderr.strip()[:160]); sys.exit(1)
    vol = [ln for ln in r.stdout.splitlines() if ln.startswith("#define volatile")]
    if g1_erases_volatile(r.stdout):
        fail("G1 -traditional erases volatile (`#define volatile` is EMPTY): the spl()/splx() "
             "asms lose volatile and gcc drops them (T-9)")
    else:
        ok("G1 volatile kept (%s)" % ("; ".join(vol) or "no #define volatile"))

    # G2
    r = subprocess.run(base + ["-E", "-P", a.source], capture_output=True, text=True, cwd=a.cwd)
    if r.returncode != 0:
        fail("G2 preprocess failed: %s" % r.stderr.strip()[:160]); sys.exit(1)
    pre = {n: spl_sites(b) for n, b in split_functions(r.stdout)}
    raw = {}
    if a.macro:
        src = a.source if os.path.isabs(a.source) else os.path.join(a.cwd or ".", a.source)
        with open(src, errors="replace") as fh:
            raw = {n: spl_sites(b, a.macro) for n, b in split_functions(fh.read())}
    sites = {}
    for n in set(pre) | set(raw):
        k = pre.get(n, 0) + raw.get(n, 0)
        if k:
            sites[n] = k
    d = subprocess.run([OBJDUMP, "-d", a.object], capture_output=True, text=True,
                       env=dict(os.environ, LC_ALL="C"))
    if d.returncode != 0:
        fail("objdump failed"); sys.exit(1)
    writes = sr_writes_by_function(d.stdout)
    bad = [n for n in sorted(sites) if n in writes and writes[n] == 0]
    missing = [n for n in sorted(sites) if n not in writes]
    detail = " ".join("%s:%d/%d" % (n, sites[n], writes.get(n, -1)) for n in sorted(sites))
    note("G2 counts (function:sites/sr-writes) %s | unit %d site(s) in %d function(s), "
         "%d sr write(s) in the object" % (detail or "none", sum(sites.values()), len(sites),
                                            sum(writes.values())))
    if missing:
        fail("G2 function(s) with spl sites but no symbol in the object: %s" % ", ".join(missing))
    if bad:
        if a.allow:
            note("G2 ALLOWLISTED -- %d function(s) call spl with no %%sr write (%s); "
                 "allowance: %s" % (len(bad), ", ".join(bad), a.allow))
        else:
            fail("G2 %d function(s) call spl but write %%sr never: %s (T-9: the masks were "
                 "dropped)" % (len(bad), ", ".join(bad)))
    elif not missing:
        ok("G2 every spl-calling function writes %%sr (%d function(s))" % len(sites))
    sys.exit(1 if failed else 0)


main()
