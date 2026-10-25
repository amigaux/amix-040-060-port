#!/usr/bin/env python3
"""kinfo-decode.py -- decode a /dev/kinfo record (docs/contracts/KINFO.md) and check its shape.

  python3 tools/kinfo-decode.py RECORD.bin
  python3 tools/kinfo-decode.py --od OD.txt         the output of `od -X /dev/kinfo` (or `od -x`)

Prints every field by name and exits 0 when the record is well formed: magic KIF1, version 2,
length 540 + 32 x modules, the longwords summing to zero, counts within bounds, a valid AXL1 or
RTH1 wherever the flags say one was found and zeros wherever they say none.
"""
import re
import struct
import sys

MOBO = {0: "motherboard", 1: "a3000-wd", 2: "gayle", 3: "a4000t-710", 4: "z3660-window"}


def from_od(text):
    out = bytearray()
    for line in text.splitlines():
        f = line.split()
        if len(f) < 2 or not re.fullmatch(r"[0-7]+", f[0]):
            continue
        for w in f[1:]:
            if not re.fullmatch(r"[0-9a-fA-F]+", w):
                continue
            n = len(w) // 2
            out += int(w, 16).to_bytes(n, "big")
    return bytes(out)


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--od":
        b = from_od(open(a[1]).read())
    elif len(a) == 1:
        b = open(a[0], "rb").read()
    else:
        raise SystemExit(__doc__)
    bad = []
    L = lambda o: struct.unpack(">I", b[o:o + 4])[0]
    s = lambda o, n: b[o:o + n].split(b"\0")[0].decode("latin-1")

    if len(b) < 540 or b[:4] != b"KIF1":
        raise SystemExit("not a KIF1 record (%d bytes)" % len(b))
    ver, length = L(4) >> 16, L(4) & 0xFFFF
    nmod = L(536)
    print("magic KIF1  version %d  length %d  (%d bytes read)" % (ver, length, len(b)))
    if ver != 2:
        bad.append("version %d" % ver)
    if length != 540 + 32 * nmod or len(b) < length:
        bad.append("length %d for %d modules, %d bytes" % (length, nmod, len(b)))
    b = b[:length]
    tot = sum(struct.unpack(">%dI" % (length // 4), b)) & 0xFFFFFFFF
    print("check 0x%08x  longword sum 0x%08x" % (L(8), tot))
    if tot:
        bad.append("the longwords sum to 0x%x" % tot)
    print("cpu %d  line %d  AttnFlags 0x%04x" % (L(12), L(16), L(20)))
    print("kabi %r  build %r" % (s(24, 24), s(48, 32)))
    fl = L(80)
    print("flags 0x%x%s%s%s" % (fl, " AXL1" if fl & 1 else "", " RTH1" if fl & 2 else "", " SAFE" if fl & 4 else ""))
    axl, rth = b[84:208], b[208:264]
    if fl & 1:
        ok = axl[:4] == b"AXL1" and sum(struct.unpack(">31I", axl)) & 0xFFFFFFFF == 0
        print("AXL1 %s: loader %d gen %d state %d flags 0x%x dev unit %d start 0x%x base 0x%x id 0x%x"
              % ("valid" if ok else "INVALID", L(96), L(112), L(116), L(120), L(128), L(132), L(136), L(140)))
        ok or bad.append("AXL1 flagged but invalid")
    elif any(axl):
        bad.append("no AXL1 flag but the field is not zero")
    if fl & 2:
        ok = rth[:4] == b"RTH1" and sum(struct.unpack(">7I", rth[:28])) & 0xFFFFFFFF == 0
        print("RTH1 %s: flags 0x%x boot unit %d base 0x%x id 0x%x root record %s"
              % ("valid" if ok else "INVALID", L(216), L(220), L(224), L(228),
                 "RTO1" if rth[28:32] == b"RTO1" else "none"))
        ok or bad.append("RTH1 flagged but invalid")
    elif any(rth):
        bad.append("no RTH1 flag but the field is not zero")
    nb = L(264)
    print("boards %d" % nb)
    if nb > 16:
        bad.append("%d boards" % nb)
    for i in range(min(nb, 16)):
        o = 268 + 12 * i
        m, p, z, base, size = struct.unpack(">HBBII", b[o:o + 12])
        print("  board %d: zorro:%04x:%02x base 0x%08x size 0x%x" % (i, m, p, base, size))
        z and bad.append("board %d byte 3 is %d" % (i, z))
    if any(b[268 + 12 * min(nb, 16):460]):
        bad.append("bytes after the last board are not zero")
    nc = L(460)
    print("sd cards %d" % nc)
    if nc > 4:
        bad.append("%d cards" % nc)
    for i in range(min(nc, 4)):
        o = 464 + 16 * i
        card, cid, base, f = struct.unpack(">IIII", b[o:o + 16])
        if f & 1:
            key = "mobo:%s" % MOBO.get(cid, "id %d" % cid)
        else:
            key = "zorro:%04x:%02x" % (cid >> 16, cid >> 8 & 0xFF)
        print("  card %d: %s base 0x%08x flags 0x%x  (disks c%x..c%xd0)" % (card, key, base, f, 8 * card, 8 * card + 7))
    print("fast %d bytes (%d MB)  chip %d bytes (%d KB)" % (L(528), L(528) >> 20, L(532), L(532) >> 10))
    print("modules %d" % nmod)
    for i in range(nmod):
        o = 540 + 32 * i
        print("  %s at 0x%08x size %d" % (s(o, 24), L(o + 24), L(o + 28)))
    print("VERDICT %s" % ("OK" if not bad else "BAD: " + "; ".join(bad)))
    sys.exit(1 if bad else 0)


main()
