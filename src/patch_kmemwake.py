#!/usr/bin/env python3
# patch_kmemwake.py -- a free of kernel map wakes the oversize sleepers whatever its size (ISSUE-82).
#
#   patch_kmemwake.py KERNEL           write; idempotent
#   patch_kmemwake.py --check KERNEL   say which form KERNEL has; write nothing
#
# THE DEFECT, stock.  kmem_alloc sleeps on Km_OsizeWanted, the smallest size in bytes anyone waits for, when sptalloc
# finds no run.  kmem_freepool wakes it only when `clicks returned >= Km_OsizeWanted`: clicks (1 or 4 here) against
# bytes (over 4096), so never.  kmem_free's oversize path compares bytes with bytes, but a free smaller than the
# request can complete a run too, by joining free space next to it, and that wakes nobody.  Both are upstream's
# reading (Antti Sokero, its ISSUE-82), where the fix was to make kmem_freepool's compare bytes.  That leaves the
# smaller frees asleep, so here neither path compares.
#
# Nor does kmem_alloc hold an spl between storing Km_OsizeWanted and sleep(): an oversize free at interrupt level in
# that window clears it and wakes nobody, and with the stock `ble.w` every later free then skips the wakeup.
#
# THE CHANGE.  The `ble.w` before each compare and the `bcs.w` after it become nops, so every pool retirement and
# every direct oversize free wakes the channel: an empty wakeup when nobody waits, and a sleeper that missed one return
# is woken by the next.  kmem_alloc's sleeper goes back to its sptalloc (.text 0x420a0, `bra` to its top) and sleeps
# again if the run is not there yet.  Frees that do not pass through kmem (sptfree directly, unkseg, bp_mapout) wake
# nobody, as before.

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
    """the `tstl Wanted; ble.w x; cmpl Wanted,%dN; bcs.w y` in a function: (.text offset of the tstl, is_new)"""
    start, size = func(e, name)
    found = []
    for off in range(start, start + size - 20, 2):
        b = e.text(off, 20)
        if b[:2] != b"\x4a\xb9" or b[10] & 0xf1 != 0xb0 or b[11] != 0xb9:
            continue
        r1, r2 = rt.get(off + 2), rt.get(off + 12)
        if r1 is None or r2 is None or e.sym(r1[1])["name"] != WANTED or e.sym(r2[1])["name"] != WANTED:
            continue
        if b[6:8] == b"\x6f\x00" and b[16:18] == b"\x65\x00":
            found.append((off, False))
        elif b[6:10] == NOP2 and b[16:20] == NOP2:
            found.append((off, True))
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
        print("  %s kmem wake: %s" % ("[ok]  " if new else "[stock]", "every return wakes" if new else "stock compares"))
        sys.exit(0 if new else 1)
    if new:
        print("  [skip] the kmem wake is already patched")
        return
    t = e.sec[".text"]["offset"]
    for (off, _), n in zip(s, FUNCS):
        e.b[t + off + 6:t + off + 10] = NOP2
        e.b[t + off + 16:t + off + 20] = NOP2
        print("  [ok]   %s .text 0x%x: ble.w and bcs.w -> nops" % (n, off))
    open(path, "wb").write(e.b)


if __name__ == "__main__":
    main()
