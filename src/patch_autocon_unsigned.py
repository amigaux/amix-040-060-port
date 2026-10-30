#!/usr/bin/env python3
# patch_autocon_unsigned.py -- make stock autocon() compare the manufacturer id unsigned, so a
# board whose AutoConfig manufacturer is >= 0x8000 can be found (2026-10-02, DRIVER-LINE-4).
#
# THE DEFECT.  autocon(pc, index, bp, np) takes the 32-bit product code in a SIGNED long and tests
# each bootinfo.autocon[] entry with `er_Manufacturer != (pc>>16)` (amiga/kernel/support.c,
# autocon).  For a code with the top bit set -- the A4092's 0xc0de0001 -- the shift is arithmetic:
# 0xFFFFC0DE, while er_Manufacturer is an unsigned short, 0x0000C0DE.  The two never compare equal,
# autocon() answers 0 for every board of that maker, sd never registers the card, and its driver is
# never called.  Every id this project met before was below 0x8000 (Commodore 0x0202, the Z3660's
# 0x144B), which is why nothing showed it until the first real A4092 (A4000D, 2026-10-02: the board
# was bootinfo.autocon[0] with the exact id, and sd's second slot stayed empty).
#
# THE FIX.  One opcode word in autocon: `asr.l %d7,%d0` (0xeea0) -> `lsr.l %d7,%d0` (0xeea8), the
# shift that takes the high half of pc.  For an id below 0x8000 both shifts give the same value, so
# every board that matched before matches identically; only ids >= 0x8000 start to match.
#
# The site is asserted by its surroundings before anything is written: autocon must be the global
# at .text 0x19222, and .text 0x19280 must hold `moveq #16,%d7; asr.l %d7,%d0; cmp.l %d5,%d0`
# (7e10 eea0 b085), or the already-patched 7e10 eea8 b085 (then nothing is written).  Anything
# else is refused.  No relocation covers these bytes.  Idempotent.

import struct, sys

AUTOCON = 0x19222
SITE = 0x19280
STOCK = bytes.fromhex("7e10eea0b085")
FIXED = bytes.fromhex("7e10eea8b085")


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_autocon_unsigned.py KERNEL")
    path = sys.argv[1]
    b = bytearray(open(path, "rb").read())
    shoff, shentsize, shnum, shstrndx = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
    sh = [dict(name=u32(b, shoff + i * shentsize), offset=u32(b, shoff + i * shentsize + 16),
               size=u32(b, shoff + i * shentsize + 20), link=u32(b, shoff + i * shentsize + 24),
               entsize=u32(b, shoff + i * shentsize + 36)) for i in range(shnum)]
    base = sh[shstrndx]["offset"]
    names = [b[base + s["name"]:b.index(b"\0", base + s["name"])].decode() for s in sh]
    sec = dict(zip(names, sh))
    st = sec[".symtab"]; stro = sh[st["link"]]["offset"]
    found = []
    for i in range(st["size"] // st["entsize"]):
        o = st["offset"] + i * st["entsize"]
        n = u32(b, o)
        if b[stro + n:b.index(b"\0", stro + n)] == b"autocon" and (b[o + 12] >> 4) == 1:
            found.append((u32(b, o + 4), names[u16(b, o + 14)]))
    if found != [(AUTOCON, ".text")]:
        raise SystemExit("ABORT: global autocon is %s, expected .text 0x%x" % (found, AUTOCON))
    rt = sec[".rela.text"]
    for i in range(rt["size"] // rt["entsize"]):
        off = u32(b, rt["offset"] + i * rt["entsize"])
        if SITE <= off < SITE + len(STOCK):
            raise SystemExit("ABORT: a relocation at .text 0x%x covers the site" % off)
    t = sec[".text"]["offset"] + SITE
    got = bytes(b[t:t + len(STOCK)])
    if got == FIXED:
        print("  [skip] autocon .text 0x%x already lsr.l (unsigned manufacturer compare)" % (SITE + 2))
        return
    if got != STOCK:
        raise SystemExit("ABORT: .text 0x%x holds %s, expected %s -- autocon is not the code this "
                         "patch was measured against" % (SITE, got.hex(), STOCK.hex()))
    b[t:t + len(STOCK)] = FIXED
    open(path, "wb").write(b)
    print("  [ok]   autocon .text 0x%x: asr.l %%d7,%%d0 -> lsr.l %%d7,%%d0 (manufacturer ids >= 0x8000 "
          "now match; below 0x8000 unchanged)" % (SITE + 2))


# Guarded: fsobj-patch.py and other readers load this file for its site tables, and an
# unguarded main() would patch whatever kernel path sits in their argv (2026-10-30).
if __name__ == "__main__":
    main()
