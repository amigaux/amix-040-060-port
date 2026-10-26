#!/usr/bin/env python3
# patch_dlm_halt.py -- mdboot's calls of haltsys and rtnfirm onto the halt-pass shims of
# src/dlm_halt040.s (amix-dlm core patch 0030, S4-07; 2026-10-26).  Run by relink-040-dlm.sh after
# its link, when the core defines dlm_halt.
#
# mdboot has exactly one `jsr haltsys` and one `jsr rtnfirm`, each an R_68K_32 relocation in its
# body; both are retargeted, and every other caller of the two (xpanic, xcmn_err, kbintr) is left
# as it is.  Each relocation is asserted first: inside mdboot, the stock symbol, addend 0.
#
# Usage: python3 patch_dlm_halt.py <image>            patch (refuses an image already patched)
#        python3 patch_dlm_halt.py --check <image>    require both retargets, and no other caller

import struct
import sys

R_68K_32 = 1
WANT = {"haltsys": "dlm_halt_haltsys", "rtnfirm": "dlm_halt_rtnfirm"}


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    a = sys.argv[1:]
    check = a[:1] == ["--check"]
    if len(a) != 1 + check:
        raise SystemExit("usage: patch_dlm_halt.py <image> | --check <image>")
    path = a[-1]
    b = bytearray(open(path, "rb").read())
    so, se, sn, ss = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
    sh = [dict(name=u32(b, so + i * se), offset=u32(b, so + i * se + 16), size=u32(b, so + i * se + 20),
               link=u32(b, so + i * se + 24), entsize=u32(b, so + i * se + 36)) for i in range(sn)]
    base = sh[ss]["offset"]
    names = [b[base + s["name"]:b.index(b"\0", base + s["name"])].decode() for s in sh]
    sec = dict(zip(names, sh))
    st = sec[".symtab"]
    stro = sh[st["link"]]["offset"]
    tidx = names.index(".text")

    def sym(i):
        o = st["offset"] + i * st["entsize"]
        n = u32(b, o)
        return dict(name=b[stro + n:b.index(b"\0", stro + n)].decode("latin1"), value=u32(b, o + 4),
                    size=u32(b, o + 8), info=b[o + 12], shndx=u16(b, o + 14))

    nsym = st["size"] // st["entsize"]
    glob = {}
    for i in range(nsym):
        s = sym(i)
        if s["shndx"] == tidx and s["info"] >> 4 == 1:
            glob.setdefault(s["name"], []).append(i)
    for n in ["mdboot"] + list(WANT) + list(WANT.values()):
        if len(glob.get(n, [])) != 1:
            raise SystemExit("ABORT: %d global .text definitions of %s" % (len(glob.get(n, [])), n))
    md = sym(glob["mdboot"][0])
    lo, hi = md["value"], md["value"] + md["size"]
    rt = sec[".rela.text"]
    found = {}
    for i in range(rt["size"] // rt["entsize"]):
        o = rt["offset"] + i * rt["entsize"]
        off, info, add = u32(b, o), u32(b, o + 4), u32(b, o + 8)
        name = sym(info >> 8)["name"]
        if name in WANT or name in WANT.values():
            inside = lo <= off < hi
            if not inside:
                if name in WANT.values():
                    raise SystemExit("ABORT: %s is called from 0x%x, outside mdboot" % (name, off))
                continue
            stock = name in WANT
            if (info & 0xFF) != R_68K_32 or add != 0 or b[sec[".text"]["offset"] + off - 2:
                                                            sec[".text"]["offset"] + off] != b"\x4e\xb9":
                raise SystemExit("ABORT: mdboot's relocation at 0x%x is not a `jsr %s`" % (off, name))
            key = name if stock else [k for k, v in WANT.items() if v == name][0]
            if key in found:
                raise SystemExit("ABORT: mdboot calls %s twice" % key)
            found[key] = (o, off, stock)
    if sorted(found) != sorted(WANT):
        raise SystemExit("ABORT: mdboot's calls found: %s" % sorted(found))
    if check:
        bad = [k for k, (_, _, stock) in found.items() if stock]
        if bad:
            raise SystemExit("patch_dlm_halt --check: mdboot still calls %s directly" % ", ".join(bad))
        print("  [OK]   mdboot -> dlm_halt_haltsys, dlm_halt_rtnfirm; no other caller of the shims")
        return
    for k, (o, off, stock) in sorted(found.items()):
        if not stock:
            raise SystemExit("ABORT: mdboot's 0x%x already names %s -- this pass has run on %s" % (off, WANT[k], path))
        struct.pack_into(">I", b, o + 4, (glob[WANT[k]][0] << 8) | R_68K_32)
        print("  [ok]   mdboot .rela.text 0x%x  %s -> %s" % (off, k, WANT[k]))
    open(path, "wb").write(b)


if __name__ == "__main__":
    main()
