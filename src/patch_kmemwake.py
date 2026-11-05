#!/usr/bin/env python3
# patch_kmemwake.py -- a free of kernel map wakes the oversize sleepers whatever its size (ISSUE-82).
#
#   patch_kmemwake.py KERNEL           write; idempotent
#   patch_kmemwake.py --check KERNEL   say which form KERNEL has; write nothing
#
# THE DEFECT, stock.  kmem_alloc sleeps on Km_OsizeWanted, the largest size in bytes anyone waits for, when sptalloc
# finds no run.  kmem_freepool wakes it only when `clicks returned >= Km_OsizeWanted`: clicks (1 or 4 here) against
# bytes (over 4096), so never.  kmem_free's oversize path compares bytes with bytes, but a free smaller than the
# request can complete a run too, by joining free space next to it, and that wakes nobody.  Both are upstream's
# reading (Antti Sokero, its ISSUE-82), where the fix was to make kmem_freepool's compare bytes.  That leaves the
# smaller frees asleep, so here neither path compares.
#
# THE CHANGE.  The `bcs.w` after each compare becomes two nops, so any return of kernel map wakes every oversize
# sleeper while one waits; the `ble.w` before the compare still skips the wakeup when nobody does.  kmem_alloc's
# sleeper goes back to its sptalloc (.text 0x420a0, `bra` to its top) and sleeps again if the run is not there yet.
# Frees that do not pass through kmem (sptfree directly, unkseg, bp_mapout) wake nobody, as before.

import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, u16, u32  # noqa: E402

WANTED = "Km_OsizeWanted"
NOP2 = b"\x4e\x71\x4e\x71"
FUNCS = ("kmem_freepool", "kmem_free")


def func(e, name):
    tidx = e.names.index(".text")
    hits = [i for i in range(e.syn) if e.sym(i)["name"] == name and e.sym(i)["shndx"] == tidx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want one %s in .text, found %d" % (name, len(hits)))
    o = e.syo + hits[0] * e.sye
    return u32(e.b, o + 4), u32(e.b, o + 8)


def site(e, rt, name):
    """the offset of the 4 bytes after `tstl Wanted; ble.w x; cmpl Wanted,%dN`: (.text offset, is_new)"""
    start, size = func(e, name)
    found = []
    for off in range(start, start + size - 20, 2):
        b = e.text(off, 20)
        if b[:2] != b"\x4a\xb9" or b[6:8] != b"\x6f\x00" or b[10] & 0xf1 != 0xb0 or b[11] != 0xb9:
            continue
        r1, r2 = rt.get(off + 2), rt.get(off + 12)
        if r1 is None or r2 is None or e.sym(r1[1])["name"] != WANTED or e.sym(r2[1])["name"] != WANTED:
            continue
        if b[16:18] == b"\x65\x00":
            found.append((off + 16, False))
        elif b[16:20] == NOP2:
            found.append((off + 16, True))
    if len(found) != 1:
        raise SystemExit("ABORT: %s: %d wake compares, want one" % (name, len(found)))
    return found[0]


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_kmemwake.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    rt = e.rela(".rela.text")
    s = [site(e, rt, n) for n in FUNCS]
    new = [x for x in s if x[1]]
    if len(new) not in (0, len(s)):
        raise SystemExit("ABORT: one of %s is patched and the other not" % (FUNCS,))
    if check:
        print("  %s kmem wake: %s" % ("[ok]  " if new else "[stock]", "any return wakes" if new else "stock compares"))
        sys.exit(0 if new else 1)
    if new:
        print("  [skip] the kmem wake is already patched")
        return
    t = e.sec[".text"]["offset"]
    for (off, _), n in zip(s, FUNCS):
        e.b[t + off:t + off + 4] = NOP2
        print("  [ok]   %s .text 0x%x: bcs.w -> nop nop" % (n, off))
    open(path, "wb").write(e.b)


if __name__ == "__main__":
    main()
