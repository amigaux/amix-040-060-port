#!/usr/bin/env python3
# patch_ddeof.py -- ISSUE-121: a raw disk read or write that starts past the end of its slice fails
# with ENXIO, not EIO or a sleep for good (2026-11-06).
#
# Stock amiga/alien/dd.c, ddread and ddwrite (the /dev/rdsk read and write entries of every disk the
# sd layer serves: the SCSI disks on the Z3660, A4091 and A3091/A2091, and the A4000's Gayle IDE disk,
# registered with sd; not the A2090 ST-506 disks of hd.c):
#
#     if (uio_offset == sddevsize(dev)*BSIZE) return 0;
#     if (uio_offset + uio_resid > sddevsize(dev)*BSIZE)
#             uio_resid = sddevsize(dev)*BSIZE - uio_offset;      <- negative past the end
#     return uiophysio(breakup, 0, dev, B_READ, uiop);
#
# A request that STARTS past the end gets a negative residue; uiophysio takes it as a byte count of
# about 4 GB.  What follows depends on the kernel and the user buffer: EIO, or (on -62) kmem_alloc
# asleep on Km_OsizeWanted at PZERO for good (kill -9 does not wake it).
# The 68030 line's dd.c.patch adds `if (uio_offset > sddevsize(dev)*BSIZE) return ENXIO;`; the
# compiler's compare there is unsigned (the clamp's bccw), and so is this one.
#
# FIX, in place, the same 14 bytes in each function (the end-of-slice test and its return 0):
#
#   ddread +0x1e  b0aa 0008   cmpl  %a2@(8),%d0           90aa 0008   subl  %a2@(8),%d0   end - off; C=X: off > end
#          +0x22  6600 0008   bnew  +0x2c                 6208        bhis  +0x2c         inside: the stock path
#          +0x26  4280        clrl  %d0                   9180        subxl %d0,%d0       -1 past the end, 0 at it
#          +0x28  6000 0048   braw  epilogue              7206        moveq #6,%d1
#                                                         c081        andl  %d1,%d0       ENXIO or 0
#                                                         6046        bras  epilogue
#
# ddwrite is the same at +0x1e with its epilogue 2 bytes nearer (6000 0046 -> 6044).  The path
# inside the slice reloads everything it uses (uio_offset, sddevsize again), so %d0 and %d1 are free
# there; the epilogue restores %d2-%d3/%a2-%a3 as before.  At the end (off == end) the result is 0
# as in stock.  tools/test-ddeof.py runs both functions' stock and patched bytes on qemu-m68k.
#
# The end is stock's `sddevsize(dev) * 512`, 32 bits, and its limits are inherited (the 030 line's C patch has them
# too): for s0 (the whole disk) sdpartition sets no length and sddevsize answers 4194303 sectors, so the end is
# 0x7ffffe00 whatever the disk's size, and past it a raw request now gets ENXIO; for a slice of 8388608 sectors (4 GiB)
# or more the product wraps, and the end is the size less a multiple of 4 GiB.
#
# Asserted before anything is written: ddread and ddwrite are one symbol each at .text 0xbd06 and
# 0xbd84, their whole bytes (the relocated fields zero), the eight R_68K_32 relocations in them name
# sddevsize, sddevsize, breakup and uiophysio.  Idempotent; --check refuses an unpatched image.
#
# Usage: python3 patch_ddeof.py <image>            patch (or skip if patched)
#        python3 patch_ddeof.py --check <image>    exit 0 only if both functions are patched

import struct
import sys

R_68K_32 = 1
EDIT = 0x1e                  # the 14 bytes replaced, from the function's start
FUNCS = {
    # name: (.text address, stock bytes with relocated fields zero, relocations {offset: symbol},
    #        stock 14 bytes at EDIT, patched 14 bytes at EDIT)
    "ddread": (0xbd06,
        "4e56000048e73030262e0008246e000c2f034eb9000000007209e3a0584f"
        "b0aa000866000008428060000048"
        "242a0008d4aa00142f0347f9000000004e937209e3a0584fb0826400"
        "00142f034e937209e3a090aa00082540"
        "0014584f2f0a487800012f0342a748790000"
        "00004eb9000000004cee0c0cfff020404e5e4e75",
        {0x14: "sddevsize", 0x38: "sddevsize", 0x68: "breakup", 0x6e: "uiophysio"},
        "b0aa0008660000084280""60000048",
        "90aa0008""6208""9180""7206""c081""6046"),
    "ddwrite": (0xbd84,
        "4e56000048e73030262e0008246e000c2f034eb9000000007209e3a0584f"
        "b0aa000866000008428060000046"
        "242a0008d4aa00142f0347f9000000004e937209e3a0584fb0826400"
        "00142f034e937209e3a090aa00082540"
        "0014584f2f0a42a72f0342a748790000"
        "00004eb9000000004cee0c0cfff020404e5e4e75",
        {0x14: "sddevsize", 0x38: "sddevsize", 0x66: "breakup", 0x6c: "uiophysio"},
        "b0aa0008660000084280""60000046",
        "90aa0008""6208""9180""7206""c081""6044"),
}


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


class Elf:
    """The few ELF facts the checks need: .text's file offset, symbols, .rela.text."""
    def __init__(self, b):
        shoff, she, shn, shs = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
        sh = [dict(name=u32(b, shoff + i * she), offset=u32(b, shoff + i * she + 16),
                   size=u32(b, shoff + i * she + 20), link=u32(b, shoff + i * she + 24),
                   entsize=u32(b, shoff + i * she + 36)) for i in range(shn)]
        base = sh[shs]["offset"]
        names = [b[base + s["name"]:b.index(b"\0", base + s["name"])].decode() for s in sh]
        self.sec = dict(zip(names, sh))
        st = self.sec[".symtab"]
        self.syms = []
        stro = sh[st["link"]]["offset"]
        for i in range(st["size"] // st["entsize"]):
            o = st["offset"] + i * st["entsize"]
            n = u32(b, o)
            self.syms.append((b[stro + n:b.index(b"\0", stro + n)].decode("latin1"), u32(b, o + 4),
                              names[u16(b, o + 14)] if u16(b, o + 14) < len(names) else None))
        self.text = self.sec[".text"]["offset"]
        rt = self.sec[".rela.text"]
        self.rela = {}
        for i in range(rt["size"] // rt["entsize"]):
            o = rt["offset"] + i * rt["entsize"]
            info = u32(b, o + 4)
            self.rela[u32(b, o)] = (info & 0xff, self.syms[info >> 8][0],
                                    struct.unpack(">i", b[o + 8:o + 12])[0])


def check_site(b, elf, name):
    """Assert one function is the code this patch was written against; return its state."""
    addr, whole, relocs, old, new = FUNCS[name]
    whole, old, new = bytes.fromhex(whole), bytes.fromhex(old), bytes.fromhex(new)
    at = [(v, s) for n, v, s in elf.syms if n == name]
    if at != [(addr, ".text")]:
        raise SystemExit("ABORT: %s is %s, expected one symbol at .text 0x%x" % (name, at, addr))
    for off, sym in relocs.items():
        r = elf.rela.get(addr + off)
        if r != (R_68K_32, sym, 0):
            raise SystemExit("ABORT: %s+0x%x relocation is %s, expected R_68K_32 %s+0" % (name, off, r, sym))
    inside = sorted(o - addr for o in elf.rela if addr <= o < addr + len(whole))
    if inside != sorted(relocs):
        raise SystemExit("ABORT: %s has relocations at %s, expected %s"
                         % (name, [hex(o) for o in inside], [hex(o) for o in sorted(relocs)]))
    cur = bytes(b[elf.text + addr:elf.text + addr + len(whole)])
    rest = cur[:EDIT] + cur[EDIT + len(old):]
    if rest != whole[:EDIT] + whole[EDIT + len(old):]:
        raise SystemExit("ABORT: %s @0x%x is not the stock dd.c code this patch was written against"
                         % (name, addr))
    edit = cur[EDIT:EDIT + len(old)]
    if edit == new:
        return "patched"
    if edit == old:
        return "stock"
    raise SystemExit("ABORT: %s+0x%x is %s, neither stock %s nor patched %s"
                     % (name, EDIT, edit.hex(), old.hex(), new.hex()))


def patch_buf(b):
    """Patch a bytearray in place; return {name: state before}."""
    elf = Elf(b)
    before = {}
    for name in FUNCS:
        before[name] = check_site(b, elf, name)
    for name, (addr, _, _, old, new) in FUNCS.items():
        o = elf.text + addr + EDIT
        b[o:o + len(old) // 2] = bytes.fromhex(new)
    return before


def unpatch_buf(b):
    """The stock bytes back (for the selftest's before case); the checks as for patching."""
    elf = Elf(b)
    for name in FUNCS:
        check_site(b, elf, name)
    for name, (addr, _, _, old, new) in FUNCS.items():
        o = elf.text + addr + EDIT
        b[o:o + len(old) // 2] = bytes.fromhex(old)


def main(argv):
    if len(argv) == 2 and argv[0] == "--check":
        b = bytearray(open(argv[1], "rb").read())
        elf = Elf(b)
        st = {n: check_site(b, elf, n) for n in FUNCS}
        if set(st.values()) != {"patched"}:
            raise SystemExit("FAIL: ISSUE-121 dd end-of-slice test not in %s: %s" % (argv[1], st))
        print("  [ok]   ISSUE-121 ddread/ddwrite past-the-end -> ENXIO present in %s" % argv[1])
        return
    if len(argv) != 1:
        raise SystemExit("usage: patch_ddeof.py [--check] <image>")
    path = argv[0]
    b = bytearray(open(path, "rb").read())
    before = patch_buf(b)
    if set(before.values()) == {"patched"}:
        print("  [skip] ISSUE-121 ddread/ddwrite already return ENXIO past the slice end")
        return
    if set(before.values()) != {"stock"}:
        raise SystemExit("ABORT: one of ddread/ddwrite patched, the other not: %s" % before)
    open(path, "wb").write(b)
    print("  [ok]   ISSUE-121 ddread @0x%x, ddwrite @0x%x: a request starting past the slice end -> ENXIO"
          % (FUNCS["ddread"][0], FUNCS["ddwrite"][0]))


# Guarded: readers load this file for its tables (tools/test-ddeof.py), and an unguarded main()
# would patch whatever path sits in their argv.
if __name__ == "__main__":
    main(sys.argv[1:])
