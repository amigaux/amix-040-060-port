#!/usr/bin/env python3
# patch_sd4card.py -- the in-place edits that give the stock sd, dd and ct four cards
# (amix-dlm C4-1, 2026-10-26).  Run by relink-040-sd4card.sh after its link; every edit is
# asserted against the bytes and relocations it expects, so a drifted base fails the build.
#
#   sd.o   the four relocations of sd's static queue[] (sdopen, sdqueue, sdhardwarename, init)
#          -> sd_queue_tbl, four slots (src/sd4card.c); init()'s `jsr insert` -> sd4_insert;
#          sdopen()'s `jsr init` -> sd4_init (the table, then the module registrations);
#          sdopen()'s bound `moveq #1,%d1` -> `moveq #3,%d1` (card < 4).  The stock insert() and
#          queue[] stay in the image, unreferenced.
#   dd.o   the two relocations of ddtab -> sd4_ddtab, four rows; the five inline sdcard()
#          decodes -> `bsr.l` to the helper of their register pair (src/sd4card040.s).
#   ct.o   the six relocations of cttab -> sd4_cttab, four rows; five dev decodes and the one
#          table-index decode likewise.
#
# A decode is the six bytes `lsrl/asrl #3,Dn; moveq #1,Dm; andl Dm,Dn`; `bsr.l <helper>` is six
# bytes too (61FF + a 32-bit displacement from the site + 2).  .text is one section, so the
# displacement needs no relocation; no relocation may touch the six bytes.
#
# Usage: python3 patch_sd4card.py <image>            patch (refuses an image already patched)
#        python3 patch_sd4card.py --check <image>    require every edit in place

import struct
import sys

R_68K_32 = 1
SD_BOUND = (0xD6CA, b"\x72\x01", b"\x72\x03")       # sdopen: moveq #1,%d1 -> #3
RELOCS = {
    0xD6D4: ("queue", "sd_queue_tbl"), 0xD700: ("queue", "sd_queue_tbl"),
    0xD722: ("queue", "sd_queue_tbl"), 0xD740: ("queue", "sd_queue_tbl"),
    0xD776: ("insert", "sd4_insert"), 0xD6C6: ("init", "sd4_init"),
    0xBECA: ("ddtab", "sd4_ddtab"), 0xBFDC: ("ddtab", "sd4_ddtab"),
    0xADA2: ("cttab", "sd4_cttab"), 0xAEDC: ("cttab", "sd4_cttab"), 0xAFFE: ("cttab", "sd4_cttab"),
    0xB076: ("cttab", "sd4_cttab"), 0xB1E2: ("cttab", "sd4_cttab"), 0xB9BE: ("cttab", "sd4_cttab"),
}
# the stock symbols by kind: ct.o also has a local FUNC named queue, and an init of 130 bytes
OLD_KIND = {"queue": (1, ".bss", 32), "insert": (2, ".text", None), "init": (2, ".text", 124),
            "ddtab": (1, ".bss", 1088), "cttab": (1, ".bss", 1152)}
SITES = {
    0xBCC4: ("e6887201c081", "sd4_dev_d0d1", "dd ddopen"),
    0xBE28: ("e6887401c082", "sd4_dev_d0d2", "dd ddioctl"),
    0xBEAC: ("e6897601c283", "sd4_dev_d1d3", "dd ddstrategy"),
    0xBF46: ("e6897401c282", "sd4_dev_d1d2", "dd ddprint"),
    0xC0EC: ("e6887201c081", "sd4_dev_d0d1", "dd startio"),
    0xAD6A: ("e6887a01c085", "sd4_dev_d0d5", "ct ctopen"),
    0xADBA: ("e6887a01c085", "sd4_dev_d0d5", "ct ctopen"),
    0xAEA4: ("e6897801c284", "sd4_dev_d1d4", "ct ctclose"),
    0xAFBE: ("e6887201c081", "sd4_dev_d0d1", "ct strategy"),
    0xB03C: ("e6807401c082", "sd4_dev_d0d2", "ct init"),
    0xB9CA: ("e6817401c282", "sd4_idx_d1d2", "ct start (a table index)"),
}


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


class Elf(object):
    def __init__(self, path):
        self.path = path
        self.b = bytearray(open(path, "rb").read())
        b = self.b
        so, se, sn, ss = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
        self.sh = [dict(name=u32(b, so + i * se), offset=u32(b, so + i * se + 16),
                        size=u32(b, so + i * se + 20), link=u32(b, so + i * se + 24),
                        entsize=u32(b, so + i * se + 36)) for i in range(sn)]
        base = self.sh[ss]["offset"]
        self.names = [b[base + s["name"]:b.index(b"\0", base + s["name"])].decode() for s in self.sh]
        self.sec = dict(zip(self.names, self.sh))
        st = self.sec[".symtab"]
        self.syo, self.sye, self.syn = st["offset"], st["entsize"], st["size"] // st["entsize"]
        self.stro = self.sh[st["link"]]["offset"]
        self.text = self.sec[".text"]["offset"]

    def sym(self, i):
        o = self.syo + i * self.sye
        n = u32(self.b, o)
        sh = u16(self.b, o + 14)
        return dict(name=self.b[self.stro + n:self.b.index(b"\0", self.stro + n)].decode("latin1"),
                    value=u32(self.b, o + 4), size=u32(self.b, o + 8), info=self.b[o + 12], shndx=sh,
                    sec=self.names[sh] if 0 < sh < len(self.names) else None)

    def index(self, name):
        hits = [i for i in range(self.syn) if self.sym(i)["name"] == name and self.sym(i)["shndx"] != 0
                and self.sym(i)["info"] >> 4 == 1]
        if len(hits) != 1:
            raise SystemExit("ABORT: %d global definitions of %s" % (len(hits), name))
        return hits[0]

    def rela(self):
        s = self.sec[".rela.text"]
        out = {}
        for i in range(s["size"] // s["entsize"]):
            o = s["offset"] + i * s["entsize"]
            out[u32(self.b, o)] = (o, u32(self.b, o + 4))
        return out


def bsrl(site, target):
    return b"\x61\xff" + struct.pack(">i", target - (site + 2))


def run(path, check):
    e = Elf(path)
    rt = e.rela()
    bad = []
    # the relocations
    for off, (old, new) in sorted(RELOCS.items()):
        if off not in rt:
            raise SystemExit("ABORT: no .rela.text entry at 0x%x" % off)
        o, info = rt[off]
        s = e.sym(info >> 8)
        if s["name"] == new:
            if not check:
                raise SystemExit("ABORT: 0x%x already names %s -- this pass has run on %s" % (off, new, path))
            continue
        if check:
            bad.append("0x%x names %s, not %s" % (off, s["name"], new))
            continue
        typ, sec, size = OLD_KIND[old]
        if (info & 0xFF) != R_68K_32 or s["name"] != old or s["info"] & 0xF != typ or s["sec"] != sec \
                or (size is not None and s["size"] != size) or u32(e.b, o + 8) != 0:
            raise SystemExit("ABORT: 0x%x is not the stock %s (%s %s size %d, type %d)"
                             % (off, old, s["name"], s["sec"], s["size"], s["info"] & 0xF))
        struct.pack_into(">I", e.b, o + 4, (e.index(new) << 8) | R_68K_32)
        print("  [ok]   .rela.text 0x%x  %s -> %s" % (off, old, new))
    # sdopen's bound
    off, was, want = SD_BOUND
    cur = bytes(e.b[e.text + off:e.text + off + 2])
    if check:
        if cur != want:
            bad.append("sdopen bound @0x%x holds %s, not 7203" % (off, cur.hex()))
    elif cur != was:
        raise SystemExit("ABORT: sdopen bound @0x%x holds %s, expected 7201" % (off, cur.hex()))
    else:
        e.b[e.text + off:e.text + off + 2] = want
        print("  [ok]   sdopen bound @0x%x  moveq #1 -> #3 (card < 4)" % off)
    # the decodes
    for off, (stock, helper, what) in sorted(SITES.items()):
        for r in rt:
            if off - 3 <= r < off + 6:
                raise SystemExit("ABORT: a relocation at 0x%x touches the decode at 0x%x" % (r, off))
        h = e.sym(e.index(helper))
        if h["sec"] != ".text":
            raise SystemExit("ABORT: %s is not in .text" % helper)
        new = bsrl(off, h["value"])
        cur = bytes(e.b[e.text + off:e.text + off + 6])
        if check:
            if cur != new:
                bad.append("%s @0x%x holds %s, not bsr.l %s" % (what, off, cur.hex(), helper))
            continue
        if cur.hex() != stock:
            raise SystemExit("ABORT: %s @0x%x holds %s, expected the stock %s" % (what, off, cur.hex(), stock))
        e.b[e.text + off:e.text + off + 6] = new
        print("  [ok]   %-24s @0x%x  sdcard() -> bsr.l %s (0x%x)" % (what, off, helper, h["value"]))
    if check:
        if bad:
            for x in bad:
                print("  [FAIL] " + x)
            raise SystemExit("patch_sd4card --check: %d edit(s) missing in %s" % (len(bad), path))
        print("  [OK]   %s: %d relocations, the sdopen bound and %d decodes in place"
              % (path, len(RELOCS), len(SITES)))
        return
    open(path, "wb").write(e.b)
    print("four cards wired -> %s" % path)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--check"] and len(a) == 2:
        run(a[1], True)
    elif len(a) == 1:
        run(a[0], False)
    else:
        raise SystemExit("usage: patch_sd4card.py <image> | --check <image>")
