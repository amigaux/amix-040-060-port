#!/usr/bin/env python3
# patch_setuid_hook.py -- remove stock AMIX 2.1's `setuid(-123456)` test panic (ISSUE-69,
# 2026-09-28).
#
# The stock setuid system call starts by comparing the requested uid with -123456 and, on a
# match, panics with "Test Panic!!!".  The compare comes before the MAXUID range check and
# before any credential check, so any user can take the machine down.  Commodore added it in
# 2.1; the 2.01/2.03 kernels and AT&T's SVR4 trees have none.  KNOWN-ISSUES.md, ISSUE-69.
#
# One byte: the `bne.w` that skips the panic (0x66 at setuid+0x14) becomes a `bra.w` (0x60).
# The skipped pea/jsr keep their relocations, so nothing the loader sees changes; the uid falls
# through to the stock range check and returns EINVAL, like every other negative uid.
#
# This is the one place this line's shipped bytes deliberately differ from upstream inside the
# stock prefix: upstream records ISSUE-69 and leaves the kernel unpatched (owner decision on
# this side, 2026-09-28).
#
#   python3 src/patch_setuid_hook.py KERNEL          patch (idempotent)
#   python3 src/patch_setuid_hook.py KERNEL --check  report; exit 0 = patched, 1 = unpatched
#                                                    (the hook is live), 2 = not recognised
#
# The site is derived, not assumed: setuid's address comes from the symbol table and must put
# the compare at .text 0x44fda, where every 2.1c kernel of this line has it; the ten bytes
# `cmpil #-123456,%a2@ ; bnew +0x14` are asserted before anything is written.

import struct, sys

SITE = 0x44FDA                   # setuid+0xe: cmpil #-123456,%a2@
OFF_IN_SETUID = 0xE
LIVE = bytes.fromhex("0c92fffe1dc066000014")
FIXED = bytes.fromhex("0c92fffe1dc060000014")
BRANCH = 6                       # offset of the branch opcode within the ten bytes


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    a = sys.argv[1:]
    if not a or len(a) > 2 or (len(a) == 2 and a[1] != "--check"):
        raise SystemExit("usage: patch_setuid_hook.py KERNEL [--check]")
    path, check = a[0], len(a) == 2
    b = bytearray(open(path, "rb").read())
    if b[:4] != b"\x7fELF":
        print("[FAIL] %s is not ELF" % path); sys.exit(2)
    so, se, sn, ss = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
    sh = [dict(name=u32(b, so + i * se), offset=u32(b, so + i * se + 16), size=u32(b, so + i * se + 20),
               link=u32(b, so + i * se + 24), entsize=u32(b, so + i * se + 36)) for i in range(sn)]
    sb = sh[ss]["offset"]
    names = [b[sb + s["name"]:b.index(b"\0", sb + s["name"])].decode() for s in sh]
    sec = dict(zip(names, sh))
    text, st = sec[".text"], sec[".symtab"]
    stro = sh[st["link"]]["offset"]
    setuid = None
    for i in range(st["size"] // st["entsize"]):
        o = st["offset"] + i * st["entsize"]
        n = u32(b, o)
        if b[stro + n:b.index(b"\0", stro + n)] == b"setuid" and u16(b, o + 14) == names.index(".text"):
            if setuid is not None:
                print("[FAIL] more than one setuid in .text"); sys.exit(2)
            setuid = u32(b, o + 4)
    if setuid is None:
        print("[FAIL] no setuid in .text"); sys.exit(2)
    if setuid + OFF_IN_SETUID != SITE:
        print("[FAIL] setuid @0x%x puts the compare at 0x%x, not 0x%x -- not the kernel this was "
              "measured on" % (setuid, setuid + OFF_IN_SETUID, SITE)); sys.exit(2)
    fo = text["offset"] + SITE
    cur = bytes(b[fo:fo + len(LIVE)])
    if cur == FIXED:
        print("      [OK]   ISSUE-69: setuid test panic removed (bra.w at .text 0x%x)" % (SITE + BRANCH))
        sys.exit(0)
    if cur != LIVE:
        print("[FAIL] .text 0x%x holds %s, expected %s or %s" % (SITE, cur.hex(), LIVE.hex(), FIXED.hex()))
        sys.exit(2)
    if check:
        print("      [--]   ISSUE-69: setuid test panic LIVE (bne.w at .text 0x%x): any user can "
              "panic this kernel with setuid(-123456)" % (SITE + BRANCH))
        sys.exit(1)
    b[fo + BRANCH] = 0x60
    open(path, "wb").write(b)
    print("      [ok]   ISSUE-69: .text 0x%x bne.w -> bra.w; setuid(-123456) now returns EINVAL"
          % (SITE + BRANCH))


main()
