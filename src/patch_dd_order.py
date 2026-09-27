#!/usr/bin/env python3
# patch_dd_order.py -- put dd.c's completion into issue-next-then-iodone order by retargeting
# the two call relocations at the tail of dd.c's `ihandle` (2026-09-27).
#
#   .rela.text @0xc0ae  R_68K_32 iodone   ->  dd_issue_first    (src/dd_order040.s)
#   .rela.text @0xc0b8  R_68K_32 startio  ->  dd_startio_tail   (src/dd_order040.s)
#
# Both, or neither: retargeting the first alone is the shape that panicked on 2026-07-31
# (docs/Z3660-KERNEL-FEASIBILITY-260731.md 5) -- it left the stock `jsr startio` after iodone in
# place, so with two buffers queued the next command was issued twice (a hypothesis for that
# panic; see docs/DD-COMPLETION-ORDER.md).  The pair is written atomically or not at all.
#
# `ihandle` is a file-static and three objects in the stock kernel each have one, so nothing here
# goes by that name.  The two sites are located by their relocations -- the only `iodone`
# relocation followed ten bytes later by a `startio` one -- asserted against the verified
# addresses, and the instruction bytes around both calls are asserted before anything is written
# (the push of bp, the two jsr opcodes, the push of dp and FIRST between them).  Only the symbol
# index in r_info changes; the addend and the .text bytes are untouched.
#
# Refuses a kernel whose @0xc0ae already names `dd_startio_first`: that is the 2026-07-31 island
# (patch_z3660.py with Z3660_DD_ORDER=1), and the two edits cannot coexist.
#
# Idempotent; fails closed on any mismatch.  Run after `ld -r` has linked build/dd_order040.o.

import struct, sys

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-dd"
R_68K_32 = 1

IODONE_SITE = 0xc0ae            # operand of `jsr iodone` in dd.c's ihandle (verified)
STARTIO_SITE = 0xc0b8           # operand of the tail `jsr startio` (verified)
EXPECT_BYTES = {                # .text offset -> the bytes that must be there
    0xc08e: bytes.fromhex("2f0c48780002"),  # push dp ; pea 2     the error path's startio(2, dp)
    0xc094: bytes.fromhex("60000020"),      # braw c0b6           ...into the shared tail call
    0xc0aa: bytes.fromhex("2f0b"),          # movel %a3,%sp@-      push bp
    0xc0ac: bytes.fromhex("4eb9"),          # jsr (abs.l)          iodone
    0xc0b2: bytes.fromhex("2f0c42a7"),      # movel %a4,%sp@- ; clrl %sp@-   push dp, FIRST
    0xc0b6: bytes.fromhex("4eb9"),          # jsr (abs.l)          startio
    0xc0bc: bytes.fromhex("4cee"),          # moveml %fp@(-16),... the return path
}
RETARGETS = [(IODONE_SITE, "iodone", "dd_issue_first"),
             (STARTIO_SITE, "startio", "dd_startio_tail")]


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

    def sym_index(name):
        found = [i for i in range(sn) if symname(i) == name]
        if len(found) != 1:
            raise SystemExit("ABORT: %d symbols named %s (want exactly one -- was "
                             "build/dd_order040.o ld -r'd in?)" % (len(found), name))
        return found[0]

    def sym_value(i):
        return u32(b, so + i * se + 4)

    text = byname[".text"]["offset"]
    for off, want in EXPECT_BYTES.items():
        got = bytes(b[text + off:text + off + len(want)])
        if got != want:
            raise SystemExit("ABORT: .text 0x%x is %s, expected %s -- dd.c's ihandle tail is not "
                             "where this patch was verified" % (off, got.hex(), want.hex()))

    rela = byname[".rela.text"]
    ro, re_ = rela["offset"], rela["entsize"]; rn = rela["size"] // re_
    for i in range(rn):
        o = ro + i * re_
        if u32(b, o) == IODONE_SITE and symname(u32(b, o + 4) >> 8) == "dd_startio_first":
            raise SystemExit("ABORT @0x%x: already retargeted to dd_startio_first -- the 2026-07-31 "
                             "island (Z3660_DD_ORDER=1) is in this kernel; the two cannot coexist"
                             % IODONE_SITE)
    at = {}
    iodone_sites = []
    for i in range(rn):
        o = ro + i * re_
        roff = u32(b, o); info = u32(b, o + 4)
        at[roff] = o
        if (info & 0xff) == R_68K_32 and symname(info >> 8) == "iodone":
            iodone_sites.append(roff)

    # The site is the only `iodone` relocation followed ten bytes later by a `startio` one.
    pairs = [r for r in iodone_sites
             if r + 10 in at and symname(u32(b, at[r + 10] + 4) >> 8) in ("startio", "dd_startio_tail")]
    already = [r for r in at if symname(u32(b, at[r] + 4) >> 8) == "dd_issue_first"]
    located = sorted(set(pairs + already))
    if located != [IODONE_SITE]:
        raise SystemExit("ABORT: the iodone/startio pair is at %s, expected [0x%x]"
                         % ([hex(x) for x in located], IODONE_SITE))

    done = skip = 0
    for site, old, new in RETARGETS:
        if site not in at:
            raise SystemExit("ABORT: no .rela.text record at 0x%x" % site)
        o = at[site]
        info = u32(b, o + 4); cur = info >> 8; typ = info & 0xff
        if typ != R_68K_32:
            raise SystemExit("ABORT @0x%x: relocation type %d != R_68K_32" % (site, typ))
        if u32(b, o + 8) != 0:
            raise SystemExit("ABORT @0x%x: addend 0x%x != 0" % (site, u32(b, o + 8)))
        tgt = sym_index(new)
        if cur == tgt:
            print("  [skip] .text 0x%x already -> %s" % (site, new))
            skip += 1
            continue
        if symname(cur) != old:
            raise SystemExit("ABORT @0x%x: current target %s, expected %s"
                             % (site, symname(cur), old))
        struct.pack_into(">I", b, o + 4, (tgt << 8) | R_68K_32)
        print("  [ok]   .text 0x%x  %s (sym %d, 0x%x) -> %s (sym %d, 0x%x)"
              % (site, old, cur, sym_value(cur), new, tgt, sym_value(tgt)))
        done += 1

    if done and skip:
        raise SystemExit("ABORT: partial retarget (%d done, %d already) -- the pair is atomic"
                         % (done, skip))

    open(KERNEL, "wb").write(b)
    print("dd.c completion order: issue-next-then-iodone -> %s" % KERNEL)


main()
