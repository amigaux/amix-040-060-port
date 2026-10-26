#!/usr/bin/env python3
# patch_free_brow.py -- free the stock RAM disk's block row, bdevsw[20], for the module ramdisk
# (amix-dlm stage 4, Q4-4; core patch 0031's block rows; 2026-10-26).  Run by relink-040-dlm.sh on a
# module kernel of kabi k46.1.1 or later.
#
# A block row is free for a module when every routine is nodev and no flag is set (the core's
# bempty(): d_flag 0 or *d_flag 0).  The stock row 20 holds the RAM disk: ramopen, ramclose,
# ramstrategy, ramprint and ramsize, then nodev, nodev and &nullflag, all as R_68K_32 relocations in
# .rela.data.  Its five routine relocations are retargeted to nodev, so the row reads as rows 21-31
# do; d_flag keeps &nullflag (0).  The RAM disk's code stays in the image, unreferenced from bdevsw.
#
# struct bdevsw is 32 bytes on this line (bdevsw .. bdevcnt = 32 rows), d_open first, d_flag at +28.
#
# Usage: python3 patch_free_brow.py <image>            patch (refuses an image already patched)
#        python3 patch_free_brow.py --check <image>    require row 20 free

import struct
import sys

R_68K_32 = 1
ROW, SIZE, NROWS = 20, 32, 32
STOCK = ["ramopen", "ramclose", "ramstrategy", "ramprint", "ramsize", "nodev", "nodev", "nullflag"]


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    a = sys.argv[1:]
    check = a[:1] == ["--check"]
    if len(a) != 1 + check:
        raise SystemExit("usage: patch_free_brow.py <image> | --check <image>")
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
    didx = names.index(".data")

    def sym(i):
        o = st["offset"] + i * st["entsize"]
        n = u32(b, o)
        return dict(name=b[stro + n:b.index(b"\0", stro + n)].decode("latin1"), value=u32(b, o + 4),
                    info=b[o + 12], shndx=u16(b, o + 14))

    glob = {}
    for i in range(st["size"] // st["entsize"]):
        s = sym(i)
        if s["info"] >> 4 == 1 and s["shndx"] != 0:
            glob.setdefault(s["name"], []).append(i)
    for n in ("bdevsw", "bdevcnt", "nodev"):
        if len(glob.get(n, [])) != 1:
            raise SystemExit("ABORT: %d global definitions of %s" % (len(glob.get(n, [])), n))
    bd, bc = sym(glob["bdevsw"][0]), sym(glob["bdevcnt"][0])
    if bd["shndx"] != didx or bc["shndx"] != didx or bc["value"] - bd["value"] != SIZE * NROWS:
        raise SystemExit("ABORT: bdevsw .. bdevcnt is not %d rows of %d bytes in .data" % (NROWS, SIZE))
    row = bd["value"] + ROW * SIZE
    rd = sec[".rela.data"]
    ent = {}
    for i in range(rd["size"] // rd["entsize"]):
        o = rd["offset"] + i * rd["entsize"]
        off = u32(b, o)
        if row <= off < row + SIZE:
            info = u32(b, o + 4)
            if (info & 0xFF) != R_68K_32 or u32(b, o + 8) != 0 or (off - row) % 4:
                raise SystemExit("ABORT: bdevsw[%d]+%d is not an R_68K_32 + 0" % (ROW, off - row))
            ent[(off - row) // 4] = (o, sym(info >> 8)["name"])
    got = [ent[k][1] if k in ent else None for k in range(8)]
    free = ["nodev"] * 7 + ["nullflag"]
    if check:
        if got != free:
            raise SystemExit("patch_free_brow --check: bdevsw[%d] is %s" % (ROW, got))
        print("  [OK]   bdevsw[%d] free: every routine nodev, d_flag &nullflag (0)" % ROW)
        return
    if got == free:
        raise SystemExit("ABORT: bdevsw[%d] is already free -- this pass has run on %s" % (ROW, path))
    if got != STOCK:
        raise SystemExit("ABORT: bdevsw[%d] is %s, not the stock RAM disk row" % (ROW, got))
    for k in range(5):
        o, name = ent[k]
        struct.pack_into(">I", b, o + 4, (glob["nodev"][0] << 8) | R_68K_32)
        print("  [ok]   bdevsw[%d] +%-2d %s -> nodev" % (ROW, 4 * k, name))
    open(path, "wb").write(b)


if __name__ == "__main__":
    main()
