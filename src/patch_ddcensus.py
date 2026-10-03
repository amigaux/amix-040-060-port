#!/usr/bin/env python3
# patch_ddcensus.py -- DIAGNOSTIC ONLY: route dd startio's one vtop call through dd_vtop_census
# (src/ddcensus040.s) by retargeting its relocation (2026-10-03, P-15 DI-1 follow-up).
#
#   .rela.text @0xc10a   vtop  ->  dd_vtop_census
#
# The shim reads startio's callee-saved %a3 (bp) and %d2 (sdblkno) at the call, so the code that
# sets them up is asserted byte for byte before anything is written:
#   0xc0c8  4e56 0000 48e7 2030 246e 000c 266a 0004   link; save d2/a2-a3; a2 = dp; a3 = dp->bhead
#   0xc0de  2f0b 4eb9 .... .... 2400                  push bp; jsr sdblkno; d2 = the block
#   0xc100  2f2b 0038 2f2b 0024 4eb9                  push b_proc; push b_un.b_addr; jsr vtop
#   0xc10e  2540 0020                                 dp->com.addr = the result
# and startio must be the one symbol of that name, at .text 0xc0c8.  Idempotent.

import struct, sys

SITE = 0xc10a
CHECKS = {
    0xc0c8: "4e56000048e72030246e000c266a0004",
    0xc0de: "2f0b4eb9",
    0xc0e6: "2400",
    0xc100: "2f2b00382f2b00244eb9",
    0xc10e: "25400020",
}
R_68K_32 = 1


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_ddcensus.py KERNEL")
    path = sys.argv[1]
    b = bytearray(open(path, "rb").read())
    shoff, she, shn, shs = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
    sh = [dict(name=u32(b, shoff + i * she), offset=u32(b, shoff + i * she + 16),
               size=u32(b, shoff + i * she + 20), link=u32(b, shoff + i * she + 24),
               entsize=u32(b, shoff + i * she + 36)) for i in range(shn)]
    base = sh[shs]["offset"]
    names = [b[base + s["name"]:b.index(b"\0", base + s["name"])].decode() for s in sh]
    sec = dict(zip(names, sh))
    st = sec[".symtab"]; stro = sh[st["link"]]["offset"]; sn = st["size"] // st["entsize"]

    def symname(i):
        o = st["offset"] + i * st["entsize"]; n = u32(b, o)
        return b[stro + n:b.index(b"\0", stro + n)].decode("latin1")

    def symval(i): return u32(b, st["offset"] + i * st["entsize"] + 4)

    starts = [(symval(i), names[u16(b, st["offset"] + i * st["entsize"] + 14)])
              for i in range(sn) if symname(i) == "startio"]
    if starts != [(0xc0c8, ".text")]:
        raise SystemExit("ABORT: startio is %s, expected one symbol at .text 0xc0c8" % starts)
    text = sec[".text"]["offset"]
    for off, want in CHECKS.items():
        got = bytes(b[text + off:text + off + len(want) // 2]).hex()
        if got != want:
            raise SystemExit("ABORT: .text 0x%x is %s, expected %s -- startio is not the code the "
                             "census was written against" % (off, got, want))
    new = [i for i in range(sn) if symname(i) == "dd_vtop_census"]
    if len(new) != 1:
        raise SystemExit("ABORT: %d dd_vtop_census symbols -- was build/ddcensus040.o linked?" % len(new))
    rt = sec[".rela.text"]
    for i in range(rt["size"] // rt["entsize"]):
        o = rt["offset"] + i * rt["entsize"]
        if u32(b, o) != SITE:
            continue
        info = u32(b, o + 4)
        cur = symname(info >> 8)
        if (info & 0xff) != R_68K_32 or struct.unpack(">i", b[o + 8:o + 12])[0] != 0:
            raise SystemExit("ABORT @0x%x: not a plain R_68K_32 with addend 0" % SITE)
        if cur == "dd_vtop_census":
            print("  [skip] startio's vtop @0x%x already -> dd_vtop_census" % SITE)
            return
        if cur != "vtop":
            raise SystemExit("ABORT @0x%x: names %s, expected vtop" % (SITE, cur))
        struct.pack_into(">I", b, o + 4, (new[0] << 8) | R_68K_32)
        open(path, "wb").write(b)
        print("  [ok]   startio's vtop @0x%x -> dd_vtop_census (DIAGNOSTIC census)" % SITE)
        return
    raise SystemExit("ABORT: no .rela.text record at 0x%x" % SITE)


main()
