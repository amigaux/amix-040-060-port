#!/usr/bin/env python3
# patch_monsw_cdevsw.py -- register /dev/monsw (src/monsw.c) in a free cdevsw row after
# monsw.o has been ld -r'd into the kernel (P-8, 2026-09-28).
#
# The patch_zz9000_cdevsw.py mechanism: a free row's d_open..d_mmap..d_* records are
# R_68K_32 relocations to `nodev`, and registration retargets some of them.  monsw has no
# read/write/mmap, so only d_open, d_close and d_ioctl move; the rest stay `nodev`.
#
# The row must be FREE: the first ten records of the row all name `nodev`.  A row that is not
# the filler is somebody else's driver (49 zz9000, 51 zen0 through d_str, 67 xsvga, 68 va2000,
# 44-46 and 48 named by the stock source), and the answer to that is to stop.  The slot offset
# is derived from the cdevsw symbol and checked against cdevcnt.
#
# usage: patch_monsw_cdevsw.py KERNEL [MAJOR]      (MAJOR defaults to 50)
# Idempotent; fails closed on any mismatch; the three retargets are one atomic group.

import struct, sys

KERNEL = sys.argv[1]
MAJOR = int(sys.argv[2]) if len(sys.argv) > 2 else 50
R_68K_32 = 1
ENTSIZE = 52                     # sizeof(struct cdevsw) on this kernel
NFREE = 10                       # records that must read `nodev` in a free row
FIELDS = {0: "monswopen", 1: "monswclose", 4: "monswioctl"}   # d_open, d_close, d_ioctl


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff = u32(b, 32); e_shentsize = u16(b, 46); e_shnum = u16(b, 48); e_shstrndx = u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(dict(name=u32(b, o), offset=u32(b, o + 16), size=u32(b, o + 20),
                       link=u32(b, o + 24), entsize=u32(b, o + 36)))
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = b.index(b"\0", shstr + s["name"]); return b[shstr + s["name"]:e].decode()

    byname = {nm(s): s for s in sh}
    symtab = byname[".symtab"]; strtab = sh[symtab["link"]]
    so, se = symtab["offset"], symtab["entsize"]; sn = symtab["size"] // se
    stroff = strtab["offset"]

    def symname(i):
        o = so + i * se; n = u32(b, o); e = b.index(b"\0", stroff + n); return b[stroff + n:e].decode()

    index = {}
    for i in range(sn):
        index.setdefault(symname(i), i)

    def sym_index(name):
        if name not in index:
            raise SystemExit("ABORT: symbol %s not found (was monsw.o ld -r'd in?)" % name)
        return index[name]

    def sym_value(name):
        return u32(b, so + sym_index(name) * se + 4)

    data = byname[".data"]["offset"]
    cdevcnt = u32(b, data + sym_value("cdevcnt"))
    if not 0 < MAJOR < cdevcnt:
        raise SystemExit("ABORT: major %d outside cdevsw[0..%d)" % (MAJOR, cdevcnt))
    slot = sym_value("cdevsw") + MAJOR * ENTSIZE

    rela = byname[".rela.data"]
    ro, re_ = rela["offset"], rela["entsize"]; rn = rela["size"] // re_
    at = {}
    for i in range(rn):
        o = ro + i * re_; roff = u32(b, o)
        if slot <= roff < slot + ENTSIZE:
            at[roff] = o

    def target(field):
        off = slot + field * 4
        if off not in at:
            raise SystemExit("ABORT: no .rela.data record at cdevsw[%d] field %d (0x%x)" % (MAJOR, field, off))
        rinfo = u32(b, at[off] + 4)
        if rinfo & 0xff != R_68K_32:
            raise SystemExit("ABORT @0x%x: reloc type %d != R_68K_32" % (off, rinfo & 0xff))
        return at[off], rinfo >> 8

    ours = all(symname(target(f)[1]) == n for f, n in FIELDS.items())
    if ours:
        rest = [f for f in range(NFREE) if f not in FIELDS]
        bad = [(f, symname(target(f)[1])) for f in rest if symname(target(f)[1]) != "nodev"]
        if bad:
            raise SystemExit("ABORT: cdevsw[%d] is ours but also names %s" % (MAJOR, bad))
        for f, n in sorted(FIELDS.items()):
            print("  [skip] cdevsw[%d] field %d already -> %s" % (MAJOR, f, n))
        print("monsw already registered (cdevsw[%d]) in %s" % (MAJOR, KERNEL))
        return
    names = [symname(target(f)[1]) for f in range(NFREE)]
    if any(n != "nodev" for n in names):
        raise SystemExit("ABORT: cdevsw[%d] is not free: %s" % (MAJOR, names))
    for f, n in sorted(FIELDS.items()):
        o, cur = target(f)
        struct.pack_into(">I", b, o + 4, (sym_index(n) << 8) | R_68K_32)
        print("  [ok]   cdevsw[%d] field %d @0x%x  nodev -> %s (0x%x)"
              % (MAJOR, f, slot + f * 4, n, sym_value(n)))
    open(KERNEL, "wb").write(b)
    print("monsw registered (cdevsw[%d], major %d) -> %s" % (MAJOR, MAJOR, KERNEL))


main()
