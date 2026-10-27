#!/usr/bin/env python3
# patch_krnx_quiet.py -- the fault resolver's FAILEXIT cmn_err onto krnx_cmn_err (src/krnx_quiet040.s),
# a module kernel's release edit (2026-10-27).  Run by relink-040-dlm.sh after its link.
#
# The site is found, not pinned: the one R_68K_32 in .text that pushes the format string
# "DBG krnxflt FAILEXIT" (krnxmemflt040.s's Lkx_fmsg, `pea`), then the `jsr cmn_err` relocation within
# 16 bytes after it.  Both are asserted; exactly one such pair must exist.
#
# Usage: python3 patch_krnx_quiet.py <image>            patch (refuses an image already patched)
#        python3 patch_krnx_quiet.py --check <image>    require the retarget

import struct
import sys

from a4091_sd_rows import Elf

R_68K_32 = 1
FMT = b"DBG krnxflt FAILEXIT"


def main():
    a = sys.argv[1:]
    check = a[:1] == ["--check"]
    if len(a) != 1 + check:
        raise SystemExit("usage: patch_krnx_quiet.py <image> | --check <image>")
    path = a[-1]
    e = Elf(path)
    data = e.sec[".data"]
    d = bytes(e.b[data["offset"]:data["offset"] + data["size"]])
    fo = d.find(FMT)
    if fo < 0 or d.find(FMT, fo + 1) >= 0:
        raise SystemExit("ABORT: the FAILEXIT format is not in .data exactly once")
    rt = e.rela(".rela.text")
    peas = [off for off, (o, si, typ, add) in rt.items() if e.target(si, add)[:2] == (".data", fo)]
    if len(peas) != 1 or e.text(peas[0] - 2, 2) != b"\x48\x79":
        raise SystemExit("ABORT: %d `pea` of the FAILEXIT format, want 1" % len(peas))
    calls = [(off, rt[off]) for off in rt if peas[0] < off <= peas[0] + 16 and e.text(off - 2, 2) == b"\x4e\xb9"]
    if len(calls) != 1:
        raise SystemExit("ABORT: %d `jsr` after the FAILEXIT format, want 1" % len(calls))
    off, (o, si, typ, add) = calls[0]
    cur = e.sym(si)["name"]
    if check:
        if cur != "krnx_cmn_err":
            raise SystemExit("patch_krnx_quiet --check: the FAILEXIT call at 0x%x still names %s" % (off, cur))
        print("  [OK]   the FAILEXIT cmn_err at .text 0x%x -> krnx_cmn_err (krnx_fail_print gates it)" % off)
        return
    if cur != "cmn_err" or typ != R_68K_32 or add != 0:
        raise SystemExit("ABORT: the FAILEXIT call at 0x%x names %s+%d, not cmn_err" % (off, cur, add))
    struct.pack_into(">I", e.b, o + 4, (e.index("krnx_cmn_err") << 8) | R_68K_32)
    open(path, "wb").write(e.b)
    print("  [ok]   the FAILEXIT cmn_err at .text 0x%x -> krnx_cmn_err" % off)


if __name__ == "__main__":
    main()
