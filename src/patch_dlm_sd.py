#!/usr/bin/env python3
# patch_dlm_sd.py -- sd4_init()'s call of sd4_noclose() onto the module core's dlm_sd_close()
# (amix-dlm C4-1 section 3, core patch 0032; 2026-10-26).  Run by relink-040-dlm.sh after its link
# when the core defines dlm_sd_close and the base carries the four-card sd (relink-040-sd4card.sh).
#
# sd4_init() (src/sd4card.c) runs sd's own init() and then, once, takes the module registrations
# through sd4_noclose(), which answers none.  Retargeting that one relocation hands the take to the
# core: dlm_sd_close(&t) returns its pending table and closes registration.  Both functions take
# one argument, a struct dlm_sdreg ** to fill, and return the count.
#
# Usage: python3 patch_dlm_sd.py <image>            patch (refuses an image already patched)
#        python3 patch_dlm_sd.py --check <image>    require the retarget

import struct
import sys

R_68K_32 = 1


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    a = sys.argv[1:]
    check = a[:1] == ["--check"]
    if len(a) != 1 + check:
        raise SystemExit("usage: patch_dlm_sd.py <image> | --check <image>")
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

    glob = {}
    for i in range(st["size"] // st["entsize"]):
        s = sym(i)
        if s["shndx"] == tidx and s["info"] >> 4 == 1:
            glob.setdefault(s["name"], []).append(i)
    for n in ("sd4_init", "sd4_noclose", "dlm_sd_close"):
        if len(glob.get(n, [])) != 1:
            raise SystemExit("ABORT: %d global .text definitions of %s" % (len(glob.get(n, [])), n))
    fn = sym(glob["sd4_init"][0])
    lo, hi = fn["value"], fn["value"] + fn["size"]
    rt = sec[".rela.text"]
    hits = []
    for i in range(rt["size"] // rt["entsize"]):
        o = rt["offset"] + i * rt["entsize"]
        off, info = u32(b, o), u32(b, o + 4)
        name = sym(info >> 8)["name"]
        if name in ("sd4_noclose", "dlm_sd_close"):
            if not lo <= off < hi:
                raise SystemExit("ABORT: %s is referenced from 0x%x, outside sd4_init" % (name, off))
            if (info & 0xFF) != R_68K_32 or u32(b, o + 8) != 0:
                raise SystemExit("ABORT: the relocation at 0x%x is not an R_68K_32 of %s + 0" % (off, name))
            hits.append((o, off, name))
    if len(hits) != 1:
        raise SystemExit("ABORT: sd4_init has %d calls of sd4_noclose/dlm_sd_close, want 1" % len(hits))
    o, off, name = hits[0]
    if check:
        if name != "dlm_sd_close":
            raise SystemExit("patch_dlm_sd --check: sd4_init still calls sd4_noclose")
        print("  [OK]   sd4_init -> dlm_sd_close (.rela.text 0x%x)" % off)
        return
    if name != "sd4_noclose":
        raise SystemExit("ABORT: sd4_init already calls dlm_sd_close -- this pass has run on %s" % path)
    struct.pack_into(">I", b, o + 4, (glob["dlm_sd_close"][0] << 8) | R_68K_32)
    open(path, "wb").write(b)
    print("  [ok]   sd4_init .rela.text 0x%x  sd4_noclose -> dlm_sd_close" % off)


if __name__ == "__main__":
    main()
