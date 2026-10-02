#!/usr/bin/env python3
"""scan060-tables.py -- run test-tools/scan060.py over a listing and accept a candidate only when it
lies inside a gcc switch dispatch table found in the same listing (2026-10-02).

scan060.py's own header says why this is needed and what it may claim: objdump decodes a switch's
offset table, which gcc places in .text right after the dispatch jump, as instructions, so a table
of 16-bit offsets can print as MOVEP.  Its verdicts are asymmetric -- CLEAN is strong, a hit is a
list to read.  This tool does the reading mechanically, for one shape only, and refuses the rest:

  the dispatch     movew %pc@(T,%dN:l:2),%d0      then      jmp %pc@(T,%d0:w)
  the bound        moveq #K,%dM  within the 4 lines before it (the `cmpl %dX,%dM; bcs/bhi`
                   range check gcc emits), so the table is T .. T + 2*(K+1)
  the candidate    a MOVEP whose address lies in [T, T + 2*(K+1)).  gcc 2.x never emits MOVEP
                   from C, so a MOVEP is a misdecode until proven otherwise; the table proves it.

Anything else -- a 64-bit multiply or divide, CMP2/CHK2/CAS2, a MOVEP outside every table, a
dispatch whose bound cannot be read -- is not accepted, and the exit status is 1.

usage: scan060-tables.py <objdump-listing>     exit 0 = every candidate explained (or CLEAN)
"""
import re
import subprocess
import sys
import os

LINE = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{4} )+)\s*(\S+)\s*(.*)$")
DISPATCH = re.compile(r"^%pc@\(([0-9a-f]+) <[^>]*>,%d\d:l:2\),%d0$")
JMP = re.compile(r"^%pc@\(([0-9a-f]+) <[^>]*>,%d0:w\)$")
MOVEQ = re.compile(r"^#(\d+),%d\d$")
HIT = re.compile(r"^\s+([0-9a-f]+)\s+(\S+)\s")


def tables(path):
    rows = []
    for raw in open(path, "r", errors="replace"):
        m = LINE.match(raw)
        if m:
            rows.append((int(m.group(1), 16), m.group(3), m.group(4).strip()))
    found = []
    for i in range(len(rows) - 1):
        a, mn, ops = rows[i]
        d = DISPATCH.match(ops) if mn == "movew" else None
        if not d:
            continue
        j = JMP.match(rows[i + 1][2]) if rows[i + 1][1] == "jmp" else None
        if not j or j.group(1) != d.group(1):
            continue
        base = int(d.group(1), 16)
        bound = None
        for k in range(max(0, i - 4), i):
            q = MOVEQ.match(rows[k][2]) if rows[k][1] == "moveq" else None
            if q:
                bound = int(q.group(1))
        found.append((a, base, bound))
    return found


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: scan060-tables.py <objdump-listing>")
    path = sys.argv[1]
    scan = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test-tools", "scan060.py")
    out = subprocess.run([sys.executable, scan, path], capture_output=True, text=True, check=True).stdout
    sys.stdout.write(out)
    if "CLEAN -- no candidate found" in out:
        return 0
    tabs = tables(path)
    for a, base, bound in tabs:
        if bound is None:
            print("   dispatch at %x: table at %x, bound NOT READ" % (a, base))
        else:
            print("   dispatch at %x: table %x..%x (%d entries)" % (a, base, base + 2 * (bound + 1) - 1, bound + 1))
    bad = 0
    for raw in out.splitlines():
        h = HIT.match(raw)
        if not h or h.group(2) in ("CLEAN", "total"):
            continue
        at, mn = int(h.group(1), 16), h.group(2)
        inside = [t for t in tabs if t[2] is not None and t[1] <= at < t[1] + 2 * (t[2] + 1)]
        if mn.startswith("movep") and inside:
            print("   %x %s: inside the table at %x -- a misdecoded offset, accepted" % (at, mn, inside[0][1]))
        else:
            print("   %x %s: NOT explained by a dispatch table -- refused" % (at, mn))
            bad += 1
    print("   %s: %d candidate(s) not explained" % ("FAIL" if bad else "OK", bad))
    return 1 if bad else 0


sys.exit(main())
