#!/usr/bin/env python3
# patch_arena8m.py -- the kernel's virtual arena (kvseg, sptmap) from 4 MiB to 8 MiB (ISSUE-80).
#
#   patch_arena8m.py KERNEL           write the values; idempotent ([skip] when already done)
#   patch_arena8m.py --check KERNEL   say whether KERNEL has the 8 MiB arena; write nothing
#
# WHY.  sptmap is 1024 clicks of 4 KiB at syssegs (0x40040000).  kvm_init's page_t array and page hash take about
# 4.6 clicks per MiB of RAM from it, a swap area's anon array one click per MiB of swap: at 128 MiB of RAM and 64 MiB
# of swap 49 clicks are free at idle (emulation, cut -62), and a KM_SLEEP kmem_alloc over 4 KiB that finds no run
# sleeps on Km_OsizeWanted.  The sizing, the sites and the >>18 key are upstream's design for its ISSUE-80 (Antti
# Sokero, KNOWN-ISSUES of amix-040-060-port's main, 62df063), written here from that description and this image.
#
# THE CHANGE, same-size immediates and two SHN_ABS values, no code added:
#     mlsetup     mfree(sptmap, 0x400, ...)         0x400 -> 0x800 clicks
#     kvm_init    seg_attach(.., syssegs, 0x400000) 4 MiB -> 8 MiB
#     sysseginit  the leaf loop's bound 1023        -> 2047: 32 leaves (8 KiB) instead of 16; its return value follows
#     kseg/unkseg ksegtbl's key (va - syssegs) >> 17 -> >> 18.  The table has 32 bytes.  kseg takes its run from
#                 ptmalloc(sptmap, n, 0x3f), aligned to 64 clicks = 256 KiB, so >> 18 is one key per allocation
#                 over 8 MiB, where >> 17 would run past the table's end.
#     kvsegmap    0x40440000 -> 0x40840000 and kvsegu 0x48440000 -> 0x48840000: the segmap window keeps its 128 MiB.
# Everything else names them by relocation, against the symbols' values here.  kptr040 has a pointer for all of
# region 1, and the kernel's only other arithmetic on these windows goes through the symbols.
#
# Every site is found inside its function by symbol, with its neighbours' relocations checked.  All old or all new is
# accepted; anything else stops the build.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, u32  # noqa: E402

SYSSEGS = 0x40040000
ABS = (("kvsegmap", 0x40440000, 0x40840000), ("kvsegu", 0x48440000, 0x48840000))
# (function, old bytes, new bytes, [(offset from the site's start, symbol a relocation there must name)])
SITES = (
    ("mlsetup", b"\x48\x78\x04\x00\x2f\x08\x4e\xb9", b"\x48\x78\x08\x00\x2f\x08\x4e\xb9", [(8, "mfree")]),
    ("kvm_init", b"\x2f\x3c\x00\x40\x00\x00", b"\x2f\x3c\x00\x80\x00\x00", []),
    ("sysseginit", b"\x0c\x81\x00\x00\x03\xff", b"\x0c\x81\x00\x00\x07\xff", []),
    ("kseg", b"\x72\x11", b"\x72\x12", [(-4, "syssegs")]),
    ("unkseg", b"\x70\x11", b"\x70\x12", [(-4, "syssegs")]),
)


def func(e, name):
    tidx = e.names.index(".text")
    hits = [i for i in range(e.syn) if e.sym(i)["name"] == name and e.sym(i)["shndx"] == tidx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want one %s in .text, found %d" % (name, len(hits)))
    o = e.syo + hits[0] * e.sye
    start, size = u32(e.b, o + 4), u32(e.b, o + 8)
    if size == 0:
        raise SystemExit("ABORT: %s has no size" % name)
    return start, size


def relocs_ok(e, rt, site, checks):
    for delta, want in checks:
        r = rt.get(site + delta)
        if r is None or e.sym(r[1])["name"] != want or r[3] != 0:
            return False
    return True


def find(e, rt, fn, pat, checks):
    start, size = func(e, fn)
    body = e.text(start, size)
    hits, at = [], 0
    while True:
        at = body.find(pat, at)
        if at < 0:
            break
        if relocs_ok(e, rt, start + at, checks):
            hits.append(start + at)
        at += 2
    return hits


def abs_sym(e, name):
    hits = [i for i in range(e.syn) if e.sym(i)["name"] == name and e.sym(i)["shndx"] == 0xfff1]
    if len(hits) != 1:
        raise SystemExit("ABORT: want one absolute %s, found %d" % (name, len(hits)))
    return e.syo + hits[0] * e.sye


def survey(e):
    """[(kind, file offset, new bytes, is_new, what)]; stops on a site that is neither old nor new"""
    if u32(e.b, abs_sym(e, "syssegs") + 4) != SYSSEGS:
        raise SystemExit("ABORT: syssegs is not 0x%x" % SYSSEGS)
    rt = e.rela(".rela.text")
    t = e.sec[".text"]["offset"]
    out = []
    for fn, old, new, checks in SITES:
        o, n = find(e, rt, fn, old, checks), find(e, rt, fn, new, checks)
        if len(o) + len(n) != 1:
            raise SystemExit("ABORT: %s: %d old and %d new sites, want one in all" % (fn, len(o), len(n)))
        out.append((t + (o or n)[0], new, bool(n), "%s .text 0x%x" % (fn, (o or n)[0])))
    for name, old, new in ABS:
        at = abs_sym(e, name) + 4
        v = u32(e.b, at)
        if v not in (old, new):
            raise SystemExit("ABORT: %s is 0x%x, neither 0x%x nor 0x%x" % (name, v, old, new))
        out.append((at, struct.pack(">I", new), v == new, "%s 0x%x" % (name, v)))
    return out


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_arena8m.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    s = survey(e)
    done = [x for x in s if x[2]]
    if len(done) not in (0, len(s)):
        raise SystemExit("ABORT: a mixed kernel: new at %s" % ", ".join(x[3] for x in done))
    if check:
        print("  %s arena: %s" % ("[ok]  " if done else "[stock]", "8 MiB" if done else "4 MiB"))
        sys.exit(0 if done else 1)
    if done:
        print("  [skip] the arena is already 8 MiB")
        return
    for at, new, _, what in s:
        e.b[at:at + len(new)] = new
        print("  [ok]   %s" % what)
    open(path, "wb").write(e.b)
    if not all(x[2] for x in survey(Elf(path))):
        raise SystemExit("ABORT: the write did not take")
    print("  [ok]   arena 4 MiB -> 8 MiB, kvsegmap 0x40840000, kvsegu 0x48840000")


# Guarded: readers may load this file for its tables, and an unguarded main() would patch their argv.
if __name__ == "__main__":
    main()
