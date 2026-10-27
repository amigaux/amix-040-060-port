#!/usr/bin/env python3
"""fsobj-patch.py -- the 4 KiB-page byte patches of a stock filesystem object, for a k46 module
(amix-dlm S5-04, the k46 half; 2026-10-27).

  python3 tools/fsobj-patch.py --stock UNIX --base BASE OBJ --triples
  python3 tools/fsobj-patch.py --stock UNIX --base BASE OBJ -o OUT

OBJ is a stock object linked whole into the stock kernel (fs/ufs/exp, fs/s5/exp).  UNIX is that
stock kernel (stand/unix), BASE the k46 base relink-040.sh made from it (build/b-new).  The module
body of a filesystem carved out of the base is OBJ with the base's patches applied at object
offsets; amix-dlm's tools/carve.py wraps it as on k30.

What is checked, and refused:
  1. OBJ is in UNIX, whole: its .text and .data bytes at one place each, and every relocation of
     OBJ at the same offset in UNIX with the same type, symbol and addend (a section symbol's
     addend shifted by where that section of OBJ starts in UNIX); the counts equal.
  2. Inside those ranges BASE has UNIX's relocations exactly.
  3. Every byte where BASE differs from UNIX in the ranges belongs to a site of the patch scripts
     that write the base (SCRIPTS below), and every site in the ranges reads its old bytes in
     UNIX and its old or its new bytes in BASE.  .data must not differ.
  4. No patched byte lies in a relocated field.
  5. Each script's canaries in the ranges read as the script expects, in UNIX and in BASE.
The sites are the scripts' own tables (P / TEXT; CANARY / PRODUCER), loaded from their source
without running them.

Output: --triples prints one line per site applied in BASE, `.text <offset> <old> <new>
<script>:<name>`, the offset relative to OBJ's .text.  -o writes OBJ with those bytes changed and
nothing else.
"""
import ast
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")
sys.path.insert(0, SRC)
import a4091_sd_rows as rows  # noqa: E402  (the ELF reader)

SCRIPTS = ["patch_modelb.py", "patch_modelb_pager.py", "patch_writeback.py", "patch_ufsbmap.py",
           "patch_pagecreate.py"]
STT_SECTION = 3
WIDTH = {1: 4, 2: 2, 3: 1, 4: 4, 5: 2, 6: 1}    # R_68K_32/16/8, PC32/16/8


def die(msg):
    raise SystemExit("fsobj-patch: " + msg)


def tables(script):
    """The script's sites [(vaddr, old, new, name)] and canaries [(vaddr, want, what)]."""
    path = os.path.join(SRC, script)
    tree = ast.parse(open(path).read(), path)
    tree.body = [n for n in tree.body if not (isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
                                              and getattr(n.value.func, "id", None) == "main")]
    ns = {"__name__": "fsobj_sites", "__file__": path}
    argv = sys.argv
    sys.argv = [path]
    try:
        exec(compile(tree, path, "exec"), ns)
    finally:
        sys.argv = argv
    sites = [t if len(t) == 4 else t[1:] for t in ns.get("P", []) + ns.get("TEXT", [])]
    for t in sites:
        if len(t) != 4 or len(t[1]) != len(t[2]):
            die("%s: a site that is not (vaddr, old, new, name): %r" % (script, t))
    return sites, ns.get("CANARY", []) + ns.get("PRODUCER", [])


def symname(e, idx):
    s = e.sym(idx)
    return e.names[s["shndx"]] if s["info"] & 0xF == STT_SECTION else s["name"]


def relocs(e, sec):
    rs = rows.Elf.rela(e, ".rela" + sec)
    return {off: (typ, symname(e, idx), add) for off, (_, idx, typ, add) in rs.items()}


def secbytes(e, sec):
    s = e.sec[sec]
    return bytes(e.b[s["offset"]:s["offset"] + s["size"]])


def locate(U, O, sec, shifts):
    """Where OBJ's section sits in UNIX: the one place its bytes and relocations both match.  A
    relocation against a section symbol fixes that section's shift; shifts collects them."""
    ob, ub = secbytes(O, sec), secbytes(U, sec)
    orl, url = relocs(O, sec), relocs(U, sec)
    found = []
    at = ub.find(ob)
    while at >= 0:
        sh = dict(shifts)
        sh.setdefault(sec, at)
        ok = sh[sec] == at and sum(1 for off in url if at <= off < at + len(ob)) == len(orl)
        for off, (t, n, add) in orl.items():
            u = url.get(at + off)
            if not ok or u is None or u[:2] != (t, n):
                ok = False
                break
            if n in (".text", ".data", ".bss"):
                sh.setdefault(n, u[2] - add)
                ok = u[2] - add == sh[n]
            else:
                ok = u[2] == add
        if ok:
            found.append(sh)
        at = ub.find(ob, at + 1)
    if len(found) != 1:
        die("%s of the object matches %d places of the stock kernel's %s, not one" % (sec, len(found), sec))
    return found[0]


def main():
    a = sys.argv[1:]
    try:
        stock, base = a[a.index("--stock") + 1], a[a.index("--base") + 1]
        rest = [x for i, x in enumerate(a) if x not in ("--stock", "--base", "--triples", "-o")
                and (i == 0 or a[i - 1] not in ("--stock", "--base", "-o"))]
        obj, = rest
        out = a[a.index("-o") + 1] if "-o" in a else None
    except (ValueError, IndexError):
        die("usage: fsobj-patch.py --stock UNIX --base BASE OBJ (--triples | -o OUT)")
    if ("--triples" in a) == (out is not None):
        die("one of --triples and -o")
    U, B, O = rows.Elf(stock), rows.Elf(base), rows.Elf(obj)

    # 1. the object in the stock kernel: .text, then .data under the shifts .text's relocations fixed
    shifts = locate(U, O, ".data", locate(U, O, ".text", {}))
    ts, ds = shifts[".text"], shifts[".data"]
    ranges = {".text": (ts, ts + O.sec[".text"]["size"]), ".data": (ds, ds + O.sec[".data"]["size"])}

    # 2. the base keeps the stock relocations in the ranges
    for sec, (lo, hi) in ranges.items():
        ur = {o: r for o, r in relocs(U, sec).items() if lo <= o < hi}
        br = {o: r for o, r in relocs(B, sec).items() if lo <= o < hi}
        if ur != br:
            die("%s 0x%x-0x%x: the base's relocations are not the stock kernel's (%d differ)"
                % (sec, lo, hi, len(set(ur.items()) ^ set(br.items()))))

    # 3. every difference is a listed site
    lo, hi = ranges[".text"]
    ut, bt = secbytes(U, ".text"), secbytes(B, ".text")
    if secbytes(U, ".data")[ds:ranges[".data"][1]] != secbytes(B, ".data")[ds:ranges[".data"][1]]:
        die(".data 0x%x-0x%x differs between the stock kernel and the base" % ranges[".data"])
    owner = {}
    applied = []
    canaries = unapplied = 0
    for script in SCRIPTS:
        sites, cans = tables(script)
        for vaddr, old, new, name in sites:
            end = vaddr + len(old)
            if end <= lo or vaddr >= hi:
                continue
            if vaddr < lo or end > hi:
                die("%s:%s @0x%x straddles the object's edge" % (script, name, vaddr))
            if ut[vaddr:end] != old:
                die("%s:%s @0x%x: the stock kernel has %s, the script expects %s"
                    % (script, name, vaddr, ut[vaddr:end].hex(), old.hex()))
            cur = bt[vaddr:end]
            if cur not in (old, new):
                die("%s:%s @0x%x: the base has %s, neither old %s nor new %s"
                    % (script, name, vaddr, cur.hex(), old.hex(), new.hex()))
            if cur == old:
                unapplied += 1
                continue
            for i in range(len(old)):
                if old[i] != new[i]:
                    if vaddr + i in owner and owner[vaddr + i][0] != new[i]:
                        die("@0x%x: %s and %s write different bytes" % (vaddr + i, owner[vaddr + i][1], script))
                    owner[vaddr + i] = (new[i], script)
            applied.append((vaddr, old, new, script, name))
        for vaddr, want, what in cans:
            if lo <= vaddr < hi:
                if ut[vaddr:vaddr + len(want)] != want or bt[vaddr:vaddr + len(want)] != want:
                    die("%s canary @0x%x (%s) is not %s" % (script, vaddr, what, want.hex()))
                canaries += 1
    diff = [o for o in range(lo, hi) if ut[o] != bt[o]]
    stray = [o for o in diff if o not in owner]
    if stray:
        die("%d changed bytes no listed site accounts for, first @0x%x" % (len(stray), stray[0]))

    # 4. no patched byte in a relocated field
    rl = relocs(U, ".text")
    for off, (t, n, add) in rl.items():
        if lo <= off < hi:
            for o in range(off, off + WIDTH.get(t, 4)):
                if o in owner:
                    die("@0x%x: a patched byte in the relocated field of %s+%d" % (o, n, add))

    applied.sort()
    tag = os.path.basename(os.path.dirname(obj)) or obj
    sys.stderr.write("fsobj-patch: %s (sha256 %s): .text 0x%x-0x%x, .data 0x%x-0x%x of the stock kernel; "
                     "%d sites applied in the base (%d bytes), %d listed but not applied, %d canaries hold\n"
                     % (tag, hashlib.sha256(open(obj, "rb").read()).hexdigest()[:8], lo, hi, ds,
                        ranges[".data"][1], len(applied), len(diff), unapplied, canaries))
    if out is None:
        for vaddr, old, new, script, name in applied:
            print(".text 0x%05x %s %s %s:%s" % (vaddr - lo, old.hex(), new.hex(), script[:-3], name))
        return
    b = bytearray(O.b)
    to = O.sec[".text"]["offset"]
    for vaddr, old, new, script, name in applied:
        b[to + vaddr - lo:to + vaddr - lo + len(new)] = new
    open(out, "wb").write(b)
    # read back: the object differs from OBJ exactly in the changed bytes, and its .text is the base's
    w = rows.Elf(out)
    if secbytes(w, ".text") != bt[lo:hi] or sum(1 for i in range(len(b)) if b[i] != O.b[i]) != len(diff):
        die("%s does not read back as the base's bytes" % out)
    sys.stderr.write("fsobj-patch: wrote %s (sha256 %s), its .text = the base's 0x%x-0x%x\n"
                     % (out, hashlib.sha256(bytes(b)).hexdigest()[:8], lo, hi))


main()
