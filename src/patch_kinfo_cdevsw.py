#!/usr/bin/env python3
# patch_kinfo_cdevsw.py -- register /dev/kinfo (src/kinfo.c) in cdevsw[53] after kinfo.o has been
# ld -r'd into the kernel (docs/contracts/KINFO.md).
#
# patch_monsw_cdevsw.py's mechanism and its free-row test, unchanged: a free row's ten function
# records are R_68K_32 relocations to `nodev`, d_ttys (+0x28) and d_str (+0x2c) are NULL words with
# no relocation, d_flag (+0x30) is `nullflag`; anything else is somebody else's driver and the
# answer is to stop.  kinfo has open, close, read and write (write answers EPERM); ioctl, mmap and
# the rest stay `nodev`.  Rows of other drivers on this line: 49 zz9000, 50 sad, 51 z3660eth (d_str
# stored at boot, so statically empty), 52 monsw, 67 xsvga, 68 va2000.
#
# usage: patch_kinfo_cdevsw.py KERNEL [MAJOR]      (MAJOR defaults to 53)
#        patch_kinfo_cdevsw.py --check KERNEL [MAJOR]   exit 0 registered, 1 free, 2 anything else
# Idempotent; fails closed on any mismatch; the four retargets are one atomic group.

import struct, sys

ARGS = sys.argv[1:]
CHECK = bool(ARGS) and ARGS[0] == "--check"
if CHECK:
    ARGS = ARGS[1:]
if not 1 <= len(ARGS) <= 2:
    raise SystemExit("usage: patch_kinfo_cdevsw.py [--check] KERNEL [MAJOR]")
KERNEL = ARGS[0]
MAJOR = int(ARGS[1]) if len(ARGS) > 1 else 53
TAKEN = {49, 50, 51, 52, 67, 68}     # rows known to belong to a driver although parts read as filler
R_68K_32 = 1
ENTSIZE = 52                     # sizeof(struct cdevsw) on this kernel
NFREE = 10                       # records that must read `nodev` in a free row
FIELDS = {0: "kinfoopen", 1: "kinfoclose", 2: "kinforead", 3: "kinfowrite"}   # d_open..d_write


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
            raise SystemExit("ABORT: symbol %s not found (was kinfo.o ld -r'd in?)" % name)
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
        if CHECK:
            print("[fixed] kinfo registered in cdevsw[%d] of %s" % (MAJOR, KERNEL))
            return
        for f, n in sorted(FIELDS.items()):
            print("  [skip] cdevsw[%d] field %d already -> %s" % (MAJOR, f, n))
        print("kinfo already registered (cdevsw[%d]) in %s" % (MAJOR, KERNEL))
        return
    names = [symname(target(f)[1]) for f in range(NFREE)]
    if any(n != "nodev" for n in names) or tail_free():
        raise SystemExit("ABORT: cdevsw[%d] is not free: %s %s" % (MAJOR, names, tail_free()))
    print("  cdevsw[%d] free: ten nodev, d_ttys/d_str NULL, d_flag nullflag" % MAJOR)
    if CHECK:
        print("[stock] cdevsw[%d] of %s is free: kinfo not registered" % (MAJOR, KERNEL))
        sys.exit(1)
    for f, n in sorted(FIELDS.items()):
        o, cur = target(f)
        struct.pack_into(">I", b, o + 4, (sym_index(n) << 8) | R_68K_32)
        print("  [ok]   cdevsw[%d] field %d @0x%x  nodev -> %s (0x%x)"
              % (MAJOR, f, slot + f * 4, n, sym_value(n)))
    open(KERNEL, "wb").write(b)
    print("kinfo registered (cdevsw[%d], major %d) -> %s" % (MAJOR, MAJOR, KERNEL))


try:
    main()
except SystemExit as x:
    if CHECK and isinstance(x.code, str):
        print(x.code)
        sys.exit(2)
    raise
