#!/usr/bin/env python3
# patch_monsw_cdevsw.py -- register /dev/monsw (src/monsw.c) in a free cdevsw row after
# monsw.o has been ld -r'd into the kernel (P-8, 2026-09-28).
#
# The patch_zz9000_cdevsw.py mechanism: a free row's d_open..d_mmap..d_* records are
# R_68K_32 relocations to `nodev`, and registration retargets some of them.  monsw has no
# read/write/mmap, so only d_open, d_close and d_ioctl move; the rest stay `nodev`.
#
# The row must be FREE, judged on the WHOLE record: d_open..d_mmap and the rest of the first ten
# name `nodev`, d_ttys (+0x28) and d_str (+0x2c) are NULL words with no relocation, and d_flag
# (+0x30) is `nullflag`.  The first version looked at the ten function records only and took
# row 50 -- which is the SAD STREAMS driver's: ten `nodev` and d_str = sadinfo, so every open went
# to stropen and monswopen never ran (PO-09, found by kerntools on DL-08).  A STREAMS driver
# lives in d_str alone, so a test that skips it cannot see one.  A row that is not the filler is
# somebody else's driver (49 zz9000, 50 sad, 51 zen0 -- d_str stored at boot by the z3660 glue,
# so statically empty and still taken -- 67 xsvga, 68 va2000, 44-46 and 48 named by the stock
# source), and the answer to that is to stop.  The slot offset is derived from the cdevsw symbol;
# cdevcnt must equal the table's own size (cdevsw .. cdevcnt / 52) and bound the row.
#
# usage: patch_monsw_cdevsw.py KERNEL [MAJOR]      (MAJOR defaults to 52)
# Idempotent; fails closed on any mismatch; the three retargets are one atomic group.

import struct, sys

KERNEL = sys.argv[1]
MAJOR = int(sys.argv[2]) if len(sys.argv) > 2 else 52
TAKEN = {49, 50, 51, 67, 68}     # rows known to belong to a driver although parts read as filler
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
    span = sym_value("cdevcnt") - sym_value("cdevsw")
    if span != cdevcnt * ENTSIZE:
        raise SystemExit("ABORT: cdevcnt %d but the table spans %d bytes (%d rows of %d)"
                         % (cdevcnt, span, span // ENTSIZE, ENTSIZE))
    if not 0 < MAJOR < cdevcnt:
        raise SystemExit("ABORT: major %d outside cdevsw[0..%d)" % (MAJOR, cdevcnt))
    if MAJOR in TAKEN:
        raise SystemExit("ABORT: cdevsw[%d] belongs to another driver (%s)" % (MAJOR, sorted(TAKEN)))
    print("  cdevcnt %d (the table's own size); row %d below it" % (cdevcnt, MAJOR))
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

    def tail_free():
        """d_ttys and d_str: NULL words with no relocation; d_flag: nullflag."""
        bad = []
        for f, what in ((10, "d_ttys"), (11, "d_str")):
            off = slot + f * 4
            if off in at:
                bad.append("%s -> %s" % (what, symname(u32(b, at[off] + 4) >> 8)))
            elif u32(b, data + off) != 0:
                bad.append("%s = 0x%x" % (what, u32(b, data + off)))
        if symname(target(12)[1]) != "nullflag":
            bad.append("d_flag -> %s" % symname(target(12)[1]))
        return bad

    ours = all(symname(target(f)[1]) == n for f, n in FIELDS.items())
    if ours:
        rest = [f for f in range(NFREE) if f not in FIELDS]
        bad = [(f, symname(target(f)[1])) for f in rest if symname(target(f)[1]) != "nodev"]
        if bad or tail_free():
            raise SystemExit("ABORT: cdevsw[%d] is ours but also names %s %s" % (MAJOR, bad, tail_free()))
        for f, n in sorted(FIELDS.items()):
            print("  [skip] cdevsw[%d] field %d already -> %s" % (MAJOR, f, n))
        print("monsw already registered (cdevsw[%d]) in %s" % (MAJOR, KERNEL))
        return
    names = [symname(target(f)[1]) for f in range(NFREE)]
    if any(n != "nodev" for n in names) or tail_free():
        raise SystemExit("ABORT: cdevsw[%d] is not free: %s %s" % (MAJOR, names, tail_free()))
    print("  cdevsw[%d] free: ten nodev, d_ttys/d_str NULL, d_flag nullflag" % MAJOR)
    for f, n in sorted(FIELDS.items()):
        o, cur = target(f)
        struct.pack_into(">I", b, o + 4, (sym_index(n) << 8) | R_68K_32)
        print("  [ok]   cdevsw[%d] field %d @0x%x  nodev -> %s (0x%x)"
              % (MAJOR, f, slot + f * 4, n, sym_value(n)))
    open(KERNEL, "wb").write(b)
    print("monsw registered (cdevsw[%d], major %d) -> %s" % (MAJOR, MAJOR, KERNEL))


# Guarded: fsobj-patch.py and other readers load this file for its site tables, and an
# unguarded main() would patch whatever kernel path sits in their argv (2026-10-30).
if __name__ == "__main__":
    main()
