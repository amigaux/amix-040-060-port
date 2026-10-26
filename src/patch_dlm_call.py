#!/usr/bin/env python3
# patch_dlm_call.py -- one call of a port stub onto the module core's hook (2026-10-26).  Run by
# relink-040-dlm.sh after its link, for each hook the core defines:
#
#   sd4_init        sd4_noclose  -> dlm_sd_close   C4-1 section 3, core patch 0032: sd's first open
#                                                  takes the pending controller registrations
#   rth1_mountroot  rth1_nomarc  -> dlm_marc_root  spec 30 section 3, core patch 0034: the arena's
#                                                  root modules link before rth1_apply
#
# The port's code calls the stub (an empty answer) until the core that has the hook is linked; then
# that one relocation is retargeted.  Asserted first: exactly one R_68K_32 of the stub or the target,
# + 0, inside FUNC, and no reference to either outside it.
#
# Usage: python3 patch_dlm_call.py IMAGE FUNC STUB TARGET            patch (refuses one already done)
#        python3 patch_dlm_call.py --check IMAGE FUNC STUB TARGET    require the retarget

import struct
import sys

R_68K_32 = 1


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    a = sys.argv[1:]
    check = a[:1] == ["--check"]
    if len(a) != 4 + check:
        raise SystemExit("usage: patch_dlm_call.py [--check] IMAGE FUNC STUB TARGET")
    path, func, stub, target = a[check:]
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

    glob = {}
    for i in range(st["size"] // st["entsize"]):
        s = sym(i)
        if s["shndx"] == tidx and s["info"] >> 4 == 1:
            glob.setdefault(s["name"], []).append(i)
    for n in (func, stub, target):
        if len(glob.get(n, [])) != 1:
            raise SystemExit("ABORT: %d global .text definitions of %s" % (len(glob.get(n, [])), n))
    fn = sym(glob[func][0])
    lo, hi = fn["value"], fn["value"] + fn["size"]
    rt = sec[".rela.text"]
    hits = []
    for i in range(rt["size"] // rt["entsize"]):
        o = rt["offset"] + i * rt["entsize"]
        off, info = u32(b, o), u32(b, o + 4)
        name = sym(info >> 8)["name"]
        if name in (stub, target):
            if not lo <= off < hi:
                raise SystemExit("ABORT: %s is referenced from 0x%x, outside %s" % (name, off, func))
            if (info & 0xFF) != R_68K_32 or u32(b, o + 8) != 0:
                raise SystemExit("ABORT: the relocation at 0x%x is not an R_68K_32 of %s + 0" % (off, name))
            hits.append((o, off, name))
    if len(hits) != 1:
        raise SystemExit("ABORT: %s has %d calls of %s/%s, want 1" % (func, len(hits), stub, target))
    o, off, name = hits[0]
    if check:
        if name != target:
            raise SystemExit("patch_dlm_call --check: %s still calls %s" % (func, stub))
        print("  [OK]   %s -> %s (.rela.text 0x%x)" % (func, target, off))
        return
    if name != stub:
        raise SystemExit("ABORT: %s already calls %s -- this pass has run on %s" % (func, target, path))
    struct.pack_into(">I", b, o + 4, (glob[target][0] << 8) | R_68K_32)
    open(path, "wb").write(b)
    print("  [ok]   %s .rela.text 0x%x  %s -> %s" % (func, off, stub, target))


if __name__ == "__main__":
    main()
