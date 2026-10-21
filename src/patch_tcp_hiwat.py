#!/usr/bin/env python3
# patch_tcp_hiwat.py -- DRIVER-LINE-10: TCP's lower read queue holds 4096 bytes, so IP frees the
# 4th and later full-size segments of every burst it passes up, and counts none of them (2026-10-21).
#
#   patch_tcp_hiwat.py KERNEL           write the fix; idempotent ([skip] when already done)
#   patch_tcp_hiwat.py --check KERNEL   say whether KERNEL carries the stock or the fixed value; write nothing
#
# THE DEFECT.  ipintr drains IP's lower read queue in one service pass and, for each datagram, asks
# canput() of TCP's lower read queue (tcplrinit: tcplrput puts, tcplrsrv feeds tcp_linput).  When it
# is full the datagram is freed: no ipstat field, no tcpstat field, STRLOG compiled out.  putq counts
# b_wptr - b_rptr, the queue's mi_hiwat is 4096, and a full segment is ~1500 bytes, so the third sets
# QFULL and the rest of the pass is lost; tcplrsrv cannot run until ipintr returns.  A 4 MiB push into
# a Z3660 box lost ~11 % of its segments to this and ran at 25 KB/s on 200 ms retransmit timeouts.
# The USL source has the same shape (netinet/ip_input.c ipintr, tcp_main.c tcpm_info).
#
# THE FIX.  One longword: mi_hiwat of tcpm_info[IQP_MUXRQ], the module_info tcplrinit points to,
# 0x1000 -> 0x4000.  That covers IP's own 8192-byte queue plus one segment, so one ipintr pass always
# fits.  mi_lowat (0x400) and the other four entries are left alone: entry 2's hiwat is the stream
# head's, read by tcpopen, and the per-connection window is SO_RCVBUF's.  The value is copied into
# q_hiwat when IP is linked under TCP at boot, so the module_info is the place that lasts.
#
# The site is found through tcplrinit's qi_minfo relocation (local symbols, exactly one each), so the
# same tool serves the stock 2.1c object (.data 0xf9c8) and every relinked base; it asserts the whole
# entry and that no relocation covers the word before writing.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a4091_sd_rows import Elf  # noqa: E402

STOCK, FIXED = 0x1000, 0x4000
ENTRY = 0x48                                 # tcpm_info[3], IQP_MUXRQ: 3 * sizeof(struct module_info)
TCPM_ID = 0xca


def u32(e, off):
    d = e.sec[".data"]["offset"]
    return struct.unpack(">I", bytes(e.b[d + off:d + off + 4]))[0]


def local(e, name, didx):
    hits = [e.sym(i) for i in range(e.syn) if e.sym(i)["name"] == name and e.sym(i)["shndx"] == didx]
    if len(hits) != 1:
        raise SystemExit("ABORT: want exactly one %s in .data, found %d" % (name, len(hits)))
    return hits[0]["value"]


def locate(e):
    didx = e.names.index(".data")
    minfo, qinit = local(e, "tcpm_info", didx), local(e, "tcplrinit", didx)
    rd = e.rela(".rela.data")
    if qinit + 0x14 not in rd:
        raise SystemExit("ABORT: tcplrinit's qi_minfo (.data 0x%x) carries no relocation" % (qinit + 0x14))
    _, si, _, add = rd[qinit + 0x14]
    sec, off = e.target(si, add)[:2]
    if (sec, off) != (".data", minfo + ENTRY):
        raise SystemExit("ABORT: tcplrinit's qi_minfo points at %s 0x%x, not tcpm_info+0x%x" % (sec, off, ENTRY))
    ent = minfo + ENTRY
    if u32(e, ent) >> 16 != TCPM_ID or u32(e, ent + 12) != 0x1000 or u32(e, ent + 20) != 0x400:
        raise SystemExit("ABORT: tcpm_info[3] is not {TCPM_ID, \"tcp\", 0, 4096, hiwat, 1024}")
    site = ent + 16
    for r in (site, site + 2):
        if r in rd:
            raise SystemExit("ABORT: a relocation at .data 0x%x covers mi_hiwat" % r)
    cur = u32(e, site)
    if cur not in (STOCK, FIXED):
        raise SystemExit("ABORT: tcpm_info[3].mi_hiwat (.data 0x%x) is 0x%x, neither 0x%x nor 0x%x"
                         % (site, cur, STOCK, FIXED))
    return site, cur


def main():
    a = sys.argv[1:]
    check = len(a) == 2 and a[0] == "--check"
    if not (len(a) == 1 or check):
        raise SystemExit("usage: patch_tcp_hiwat.py [--check] KERNEL")
    path = a[-1]
    e = Elf(path)
    site, cur = locate(e)
    if check:
        print("  %s tcpm_info[3].mi_hiwat .data 0x%x = 0x%x (%s)" % ("[ok]  " if cur == FIXED else "[stock]", site,
              cur, "fixed" if cur == FIXED else "stock: IP frees the 4th segment of a burst"))
        sys.exit(0 if cur == FIXED else 1)
    if cur == FIXED:
        print("  [skip] tcpm_info[3].mi_hiwat .data 0x%x is already 0x%x" % (site, FIXED))
        return
    d = e.sec[".data"]["offset"] + site
    e.b[d:d + 4] = struct.pack(">I", FIXED)
    open(path, "wb").write(e.b)
    if locate(Elf(path))[1] != FIXED:
        raise SystemExit("ABORT: the write did not take")
    print("  [ok]   tcpm_info[3].mi_hiwat .data 0x%x: 0x%x -> 0x%x (TCP lower read queue)" % (site, STOCK, FIXED))


main()
