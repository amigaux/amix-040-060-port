#!/usr/bin/env python3
"""check_dlm_splice.py -- the module core's splice, checked on the spliced kernel (relink-040-dlm.sh).

  python3 src/check_dlm_splice.py BASE OUT
  python3 src/check_dlm_splice.py --free-rows MAJOR[,MAJOR...] KERNEL

BASE is the kernel before the splice, OUT the ld -r of the weakened base with the core.  For each
object the core replaces (dmainit, execsw, fmodsw, scrcon_put, aciabintr):
  - OUT has one definition of the name, global, and it lies past BASE's own section (the core's);
  - __amix_<name>, where the core keeps the stock one, is at the stock address in BASE;
  - no relocation in OUT reaches the stock object but through __amix_<name>: every reference the
    stock kernel made by name now binds to the core's, and none bypasses it as section + offset or
    through a local label (U5).
The stock object's extent is the distance to the next symbol of BASE in its section.

--free-rows: each cdevsw row named is free for a module (amix-dlm M-REG1): its ten entry points
are nodev or nulldev, d_ttys and d_str are 0 with no relocation, and no relocation in .text
reaches into the row -- nothing fills it at boot, as z3660eth's parinit store did for row 51.
Prints one line per check; exit status 1 if any fails.
"""
import sys

from a4091_sd_rows import Elf

REPLACED = (("dmainit", ".text"), ("execsw", ".data"), ("fmodsw", ".data"),
            ("scrcon_put", ".text"), ("aciabintr", ".text"))
ALIASED = ("execsw", "fmodsw", "scrcon_put", "aciabintr")
STB_GLOBAL, STB_WEAK = 1, 2
fails = 0


def check(ok, what):
    global fails
    print(("[ok]   " if ok else "[FAIL] ") + what)
    fails += not ok


def table(e):
    out = []
    for i in range(e.syn):
        s = e.sym(i)
        if 0 < s["shndx"] < len(e.names) and s["name"]:
            out.append((s["name"], e.names[s["shndx"]], s["value"], s["info"] >> 4))
    return out


CDEVSZ = 52


def free_rows(e, majors):
    ci = e.index("cdevsw")
    cs = e.sym(ci)
    if e.names[cs["shndx"]] != ".data":
        check(False, "cdevsw is not in .data")
        return
    data = e.rela(".rela.data")
    text = e.rela(".rela.text")
    d0 = e.sec[".data"]["offset"]
    for m in majors:
        lo = cs["value"] + CDEVSZ * m
        ok, why = True, []
        for k in range(10):
            r = data.get(lo + 4 * k)
            t = e.target(r[1], r[3])[2] if r else None
            if t not in ("nodev", "nulldev"):
                ok = False
                why.append("entry %d -> %s" % (k, t))
        for k, f in ((10, "d_ttys"), (11, "d_str")):
            v = int.from_bytes(e.b[d0 + lo + 4 * k:d0 + lo + 4 * k + 4], "big")
            if (lo + 4 * k) in data or v:
                ok = False
                why.append("%s set" % f)
        fill = 0
        for off, (o, si, typ, add) in text.items():
            tsec, toff, tname, _ = e.target(si, add)
            if tsec == ".data" and lo <= toff < lo + CDEVSZ:
                fill += 1
        if fill:
            ok = False
            why.append("%d .text reference(s) into the row" % fill)
        check(ok, "cdevsw[%d] free, not filled at boot%s" % (m, (": " + "; ".join(why)) if why else ""))


if sys.argv[1] == "--free-rows":
    free_rows(Elf(sys.argv[3]), [int(x) for x in sys.argv[2].split(",")])
    print("check_dlm_splice: %d failed" % fails)
    sys.exit(1 if fails else 0)

base, out = Elf(sys.argv[1]), Elf(sys.argv[2])
bt, ot = table(base), table(out)
for name, sec in REPLACED:
    stock = [v for n, s, v, b in bt if n == name and s == sec]
    if len(stock) != 1:
        check(False, "%s: %d definitions in the base" % (name, len(stock)))
        continue
    lo = stock[0]
    hi = min([v for n, s, v, b in bt if s == sec and v > lo] + [base.sec[sec]["size"]])
    defs = [(v, b) for n, s, v, b in ot if n == name]
    check(len(defs) == 1 and defs[0][1] == STB_GLOBAL and defs[0][0] >= base.sec[sec]["size"],
          "%s: one global definition, the core's (%s)" % (name, ", ".join("%s 0x%x bind %d" % (sec, v, b) for v, b in defs)))
    if name in ALIASED:
        al = [v for n, s, v, b in ot if n == "__amix_" + name and s == sec]
        check(al == [lo], "__amix_%s at the stock %s 0x%x" % (name, sec, lo))
    bad = 0
    for rs in (".rela.text", ".rela.data"):
        for off, (o, si, typ, add) in out.rela(rs).items():
            if rs == ".rela" + sec and lo <= off < hi:
                continue        # the stock body's own references, kept as __amix_<name>
            tsec, toff, tname, _ = out.target(si, add)
            if tsec == sec and lo <= toff < hi and tname not in (name, "__amix_" + name):
                bad += 1
    via = " but __amix_" + name if name in ALIASED else ""
    check(bad == 0, "%s: no reference into the stock object%s (%s 0x%x..0x%x): %d"
          % (name, via, sec, lo, hi, bad))
weak = sorted(n for n, s, v, b in ot if b == STB_WEAK)
check(not weak, "no weak definition: %s" % (" ".join(weak) or "none"))
print("check_dlm_splice: %d failed" % fails)
sys.exit(1 if fails else 0)
