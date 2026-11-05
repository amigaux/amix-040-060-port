#!/usr/bin/env python3
# patch_dma_bounce.py -- dma_pageio's bounce buffer carries no process (ISSUE-116).
#
#   patch_dma_bounce.py KERNEL           write; idempotent
#   patch_dma_bounce.py --check KERNEL   say which form KERNEL has; write nothing
#
# dma_pageio gets its bounce buffer from ngeteblk, an address in the kernel's identity window, and copies the request's
# b_proc into it: `movel %a3@(56),%a2@(56)`.  A driver's vtop(b_addr, b_proc) on that buffer then names a kernel
# address and a user process together.  amiga_dma_pageio clears the field instead, and vtop040.s now walks the process's
# tables for a low address with a process, so here the copy becomes `clrl %a2@(56); nop`.  Upstream's reading of the
# same shape (Antti Sokero), where it is what stands in the way of walking low addresses with a process.

import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kelf import Elf, u32  # noqa: E402

OLD = b"\x25\x6b\x00\x38\x00\x38"
NEW = b"\x42\xaa\x00\x38\x4e\x71"


def locate(e):
    tidx = e.names.index(".text")
    hits = [i for i in range(e.syn) if e.sym(i)["name"] == "dma_pageio" and e.sym(i)["shndx"] == tidx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want one dma_pageio in .text, found %d" % len(hits))
    o = e.syo + hits[0] * e.sye
    start, size = u32(e.b, o + 4), u32(e.b, o + 8)
    body = e.text(start, size)
    no, nn = body.count(OLD), body.count(NEW)
    if no + nn != 1:
        raise SystemExit("ABORT: dma_pageio: %d copies and %d clears of b_proc, want one" % (no, nn))
    return start + body.find(OLD if no else NEW), nn == 1


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_dma_bounce.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    off, done = locate(e)
    if check:
        print("  %s dma_pageio .text 0x%x: the bounce buffer's b_proc %s" % ("[ok]  " if done else "[stock]", off, "cleared" if done else "copied"))
        sys.exit(0 if done else 1)
    if done:
        print("  [skip] dma_pageio already clears the bounce buffer's b_proc")
        return
    t = e.sec[".text"]["offset"]
    e.b[t + off:t + off + len(NEW)] = NEW
    open(path, "wb").write(e.b)
    print("  [ok]   dma_pageio .text 0x%x: b_proc copy -> clrl" % off)


if __name__ == "__main__":
    main()
