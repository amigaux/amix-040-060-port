#!/usr/bin/env python3
# patch_pageio4k.py -- DRIVER-LINE-5: raw disk transfers and buf_breakup's later pieces go out in 4 KiB, the page,
# not the stock 2 KiB (2026-11-22).
#
#   patch_pageio4k.py KERNEL           write the three constants; idempotent ([skip] when already done)
#   patch_pageio4k.py --check KERNEL   fail unless KERNEL carries all three new constants; write nothing
#
# THE THREE SITES.  The Model-B conversion left three `pea 0x800` (2048, the 030 page) in the disk paths
# (patch_modelb.py's list of sites not flipped):
#   amiga_dma_pageio .text 0xdbbe   ngeteblk(2048): the raw path's staging buffer (amiga/alien/physdsk.c)
#   amiga_dma_pageio .text 0xdd58   min(resid, 2048): each raw piece, staged through that buffer and handed to
#                                    the strategy routine as one request (one sdcom: one physical address, one length)
#   buf_breakup      .text 0x3d21e  min(resid, 2048): every piece after the first of a block request over 4 KiB
#                                    (gen_strategy -> buf_breakup, common fs/bio.c)
# so a raw read or write of N bytes reached the host adapter as N/2048 requests (measured: 8192 commands of 2048
# bytes per 16 MiB at every bs), and an 8 KiB block request as four.  Each becomes `pea 0x1000`.
#
# WHY 4 KiB STAYS IN ONE FRAME.  The driver moves each request linearly from one vtop'd address, so a piece must not
# cross a physical frame.
#   raw: every piece is staged at the start of the one ngeteblk buffer.  ngeteblk's data comes from getfreeblk:
#        a free buffer of exactly that b_bufsize, or kmem_zalloc(size); either way kmem_alloc(4096).  kmem_alloc
#        serves 257..4096 bytes from the big pools: kmem_allocbpool takes 4 pages from sptalloc, rounds the start
#        up and the end down to 4096 (addil #4095 / andiw #-4096) and lists the pool's blocks on the 4096 list at
#        base + k*4096; smaller blocks are buddies of those.  So a 4096-byte block is one page-aligned page.
#   block: buf_breakup's first piece runs to the page boundary (min(bcount, 4096 - (addr & 4095)), converted
#        earlier), or is skipped when the buffer is page-aligned; every later piece starts on a page, so
#        min(resid, 4096) ends on one.  gen_strategy still passes a request of 4096 bytes or less whole, as before.
#
# Asserted before anything is written: the two functions are one symbol each at the addresses below, each site holds
# `pea 0x800` (48780800) followed by the stock bytes up to its call, and the call's R_68K_32 names ngeteblk or min.
# The patched instruction is the same length and carries no relocation.  PAGEIO4K=0 in relink-040.sh builds without it.

import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a4091_sd_rows import Elf  # noqa: E402

OLD, NEW = bytes.fromhex("48780800"), bytes.fromhex("48781000")
FUNCS = {"amiga_dma_pageio": 0xdba8, "buf_breakup": 0x3d17a}
# (site, function, the stock bytes after the pea up to the jsr's operand, the call's target)
SITES = [
    (0xdbbe, "amiga_dma_pageio", "4eb9", "ngeteblk"),
    (0xdd58, "amiga_dma_pageio", "2f2b00304eb9", "min"),
    (0x3d21e, "buf_breakup", "2f044eb9", "min"),
]


def verify(e, want):
    """the state of each site: 'old' or 'new'; aborts on anything else"""
    for name, addr in FUNCS.items():
        hits = [e.sym(i)["value"] for i in range(e.syn) if e.sym(i)["name"] == name and e.sym(i)["shndx"] != 0]
        if hits != [addr]:
            raise SystemExit("ABORT: %s at %s, want one at .text 0x%x" % (name, [hex(h) for h in hits], addr))
    rel = e.rela(".rela.text")
    states = []
    for site, fn, tail, callee in SITES:
        t = bytes.fromhex(tail)
        got = e.text(site, 4)
        if got not in (OLD, NEW) or e.text(site + 4, len(t)) != t:
            raise SystemExit("ABORT: %s .text 0x%x is %s, not pea 0x800/0x1000 then %s"
                             % (fn, site, e.text(site, 4 + len(t)).hex(), tail))
        for o in range(site, site + 4):
            if o in rel:
                raise SystemExit("ABORT: a relocation covers %s .text 0x%x" % (fn, site))
        r = rel.get(site + 4 + len(t))
        if r is None or e.sym(r[1])["name"] != callee:
            raise SystemExit("ABORT: %s .text 0x%x: the call after it is not to %s" % (fn, site, callee))
        states.append("new" if got == NEW else "old")
    if want and any(s != want for s in states):
        return False, states
    return True, states


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_pageio4k.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    ok, states = verify(e, "new" if check else None)
    if check:
        for (site, fn, _, callee), s in zip(SITES, states):
            print("  %s %s .text 0x%x (%s): %s" % ("[ok]  " if s == "new" else "[FAIL]", fn, site, callee,
                                                    "4096" if s == "new" else "2048, stock"))
        sys.exit(0 if ok else 1)
    if all(s == "new" for s in states):
        print("  [skip] amiga_dma_pageio and buf_breakup already carry 4096")
        return
    t = e.sec[".text"]["offset"]
    for site, fn, _, callee in SITES:
        e.b[t + site:t + site + 4] = NEW
    open(path, "wb").write(e.b)
    if verify(Elf(path), "new")[0] is not True:
        raise SystemExit("ABORT: the write did not take")
    for site, fn, _, callee in SITES:
        print("  [ok]   %s .text 0x%x: %s(.., 2048) -> 4096" % (fn, site, callee))


# Guarded: readers may load this file for its tables, and an unguarded main() would patch their argv.
if __name__ == "__main__":
    main()
