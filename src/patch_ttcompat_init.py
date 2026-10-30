#!/usr/bin/env python3
# patch_ttcompat_init.py -- DRIVER-LINE-7: stock ttcompatopen() leaves the three fields the ioctl
# acknowledgement path trusts uninitialised, so a console stream can panic the kernel with
# "ttcompat: unexpected ioctl acknowledgment" at boot (2026-10-05).
#
#   patch_ttcompat_init.py KERNEL           write the fix; idempotent ([skip] when already done)
#   patch_ttcompat_init.py --check KERNEL   say whether KERNEL carries the stock or the fixed bytes; write nothing
#
# THE DEFECT.  ttcompatopen allocb()s its 0x44-byte per-stream state and points q_ptr at b_rptr.
# It clears bytes 4..31 and nothing else, so t_state (+56), t_iocid (+60) and t_ioccmd (+64) keep
# whatever the reused STREAMS buffer last held.  ttcompat_ioctl_ack takes an M_IOCACK as its own when
# bit 3 (TS_IOCWAIT) of t_state is set and ioc_id equals t_iocid, and then switches on t_ioccmd; a
# command it never sent reaches the switch's default, which panics.  The generic SVR4 source has the
# same shape (io/ttcompat.c, ttcompatopen: it initialises t_savbp, t_iocpending and t_curstate only).
#
# THE FIX.  Same length, no relocation, no layout change.  The 16 single-byte clears of bytes 12..27
# (`clrb %a0@(n)`, 64 bytes of code at ttcompatopen+0x80) become four longword clears of the same 16
# bytes plus longword clears of +56, +60 and +64, and the rest of the span is nops.  %a0 holds the
# state there (b_rptr of the new block).  Everything ttcompatopen cleared before is still cleared.
#
# The site is found by symbol (the local `ttcompatopen`, exactly one), so the same tool serves the
# 68040/060 line (.text 0x36f7c in its bases) and the 68030 kit's ET_REL (0x39a38 in K030-U); it asserts
# the 64 stock bytes and that no relocation covers them before writing.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a4091_sd_rows import Elf  # noqa: E402

OFF = 0x80                                   # from ttcompatopen
STOCK = b"".join(struct.pack(">HH", 0x4228, n) for n in range(0x0c, 0x1c))      # clrb %a0@(12..27)
FIXED = b"".join(struct.pack(">HH", 0x42a8, n) for n in (0x0c, 0x10, 0x14, 0x18, 0x38, 0x3c, 0x40)) \
    + b"\x4e\x71" * 18                                                           # clrl ...; nops
assert len(STOCK) == len(FIXED) == 64
BEFORE = bytes.fromhex("42a8000442a80008")   # clrl %a0@(4); clrl %a0@(8) -- the stock lines in front
AFTER = bytes.fromhex("42a8001c")            # clrl %a0@(28)                 -- and behind


def locate(e):
    tidx = e.names.index(".text")
    hits = [e.sym(i) for i in range(e.syn)
            if e.sym(i)["name"] == "ttcompatopen" and e.sym(i)["shndx"] == tidx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want exactly one ttcompatopen in .text, found %d" % len(hits))
    site = hits[0]["value"] + OFF
    if e.text(site - 8, 8) != BEFORE or e.text(site + 64, 4) != AFTER:
        raise SystemExit("ABORT: the code around ttcompatopen+0x%x is not the stock clear sequence" % OFF)
    rt = e.rela(".rela.text") if ".rela.text" in e.sec else {}    # an object without relocations has none
    for off in rt:
        if site <= off < site + 64:
            raise SystemExit("ABORT: a relocation at .text 0x%x lies in the span" % off)
    cur = e.text(site, 64)
    if cur not in (STOCK, FIXED):
        raise SystemExit("ABORT: ttcompatopen+0x%x holds neither the stock nor the fixed bytes" % OFF)
    return site, cur


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_ttcompat_init.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    site, cur = locate(e)
    if check:
        print("  %s ttcompatopen .text 0x%x: %s" % ("[ok]  " if cur == FIXED else "[stock]", site,
              "t_state/t_iocid/t_ioccmd cleared at open (fixed)" if cur == FIXED else "stock: those fields left uninitialised"))
        sys.exit(0 if cur == FIXED else 1)
    if cur == FIXED:
        print("  [skip] ttcompatopen .text 0x%x already clears t_state/t_iocid/t_ioccmd" % site)
        return
    t = e.sec[".text"]["offset"] + site
    e.b[t:t + 64] = FIXED
    open(path, "wb").write(e.b)
    if locate(Elf(path))[1] != FIXED:
        raise SystemExit("ABORT: the write did not take")
    print("  [ok]   ttcompatopen .text 0x%x: clears t_state/t_iocid/t_ioccmd (+56/+60/+64) at open" % site)


# Guarded: fsobj-patch.py and other readers load this file for its site tables, and an
# unguarded main() would patch whatever kernel path sits in their argv (2026-10-30).
if __name__ == "__main__":
    main()
