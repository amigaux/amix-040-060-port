#!/usr/bin/env python3
# a4091_sd_rows.py -- the sd.c side of the A4091/A4092 registration on the driver line
# (PO-04, 2026-09-28).  Two modes, run by relink-040-a4091.sh on either side of its link.
#
#   gen BASE OUT.s OUT.syms   read BASE's controller table as sd's init() will walk it -- the
#                             symbol the `lea <table>,%a3` relocation at .text+0xd74c names,
#                             and the rows 0..N of the `moveq #N,%d1` bound at .text+0xd79f --
#                             and write a new table, a4091_scsicard: every existing row first,
#                             then A4091 (0x02020054) and A4092 (0xc0de0001), both on a4091queue.
#                             OUT.syms gets the objcopy --add-symbol arguments the table needs:
#                             aliases for the existing rows' queue functions and name strings
#                             where those have no global name, and sd_queue_tbl, sd.o's static
#                             controller array (for src/sdcardbase040.s).
#   patch KERNEL OLDTABLE     after the link: retarget that relocation OLDTABLE -> a4091_scsicard
#                             and the bound to the new row count - 1.  Idempotent; the two edits
#                             are one group; everything is asserted against the bytes first.
#
# WHY THE NEW ROWS GO LAST.  sd's insert() keeps two controllers (SDCARDS) and drops a newcomer
# once both slots are full, so a row's position decides which board loses when three answer.
# Rows after every existing row never displace a board the base already registers.
#
# The existing rows are reproduced by relocation, not by value: each row's queue pointer and
# name pointer point at exactly what the base's table pointed at.

import struct, sys

LEA_SITE, LEA_RELOC = 0xD74A, 0xD74C          # `lea <table>,%a3` and its operand
BOUND_SITE = 0xD79E                           # `moveq #N,%d1`: init() walks rows 0..N
QUEUE_LEAS = (0xD6D2, 0xD6FE, 0xD720)         # sdopen, sdqueue, sdhardwarename: `lea queue,%a0`
ROW = 12
NEW_ROWS = [(0x02020054, "A4091 SCSI"), (0xC0DE0001, "A4092 SCSI")]
NEW_TABLE = "a4091_scsicard"
R_68K_32, STT_SECTION = 1, 3


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]
def i32(b, o): return struct.unpack(">i", b[o:o + 4])[0]


class Elf(object):
    def __init__(self, path):
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

    def sym(self, i):
        o = self.syo + i * self.sye
        n = u32(self.b, o)
        return dict(name=self.b[self.stro + n:self.b.index(b"\0", self.stro + n)].decode("latin1"),
                    value=u32(self.b, o + 4), info=self.b[o + 12], shndx=u16(self.b, o + 14))

    def index(self, name):
        for i in range(self.syn):
            s = self.sym(i)
            if s["name"] == name and s["shndx"] != 0:
                return i
        raise SystemExit("ABORT: no defined symbol %s" % name)

    def rela(self, secname):
        s = self.sec[secname]
        out = {}
        for i in range(s["size"] // s["entsize"]):
            o = s["offset"] + i * s["entsize"]
            info = u32(self.b, o + 4)
            out[u32(self.b, o)] = (o, info >> 8, info & 0xFF, i32(self.b, o + 8))
        return out

    def target(self, symidx, addend):
        """(section, offset, symbol name, is_global_named)"""
        s = self.sym(symidx)
        sec = self.names[s["shndx"]] if 0 < s["shndx"] < len(self.names) else None
        if s["info"] & 0xF == STT_SECTION:
            return sec, addend, None, False
        return sec, s["value"] + addend, s["name"], (s["info"] >> 4) == 1 and addend == 0

    def text(self, off, n):
        t = self.sec[".text"]["offset"]
        return bytes(self.b[t + off:t + off + n])


def read_table(e):
    if e.text(LEA_SITE, 2) != b"\x47\xf9":
        raise SystemExit("ABORT: .text+0x%x is not `lea <abs>,%%a3`" % LEA_SITE)
    if e.text(BOUND_SITE, 1) != b"\x72":
        raise SystemExit("ABORT: .text+0x%x is not a moveq" % BOUND_SITE)
    bound = e.text(BOUND_SITE + 1, 1)[0]
    rt = e.rela(".rela.text")
    if LEA_RELOC not in rt or rt[LEA_RELOC][2] != R_68K_32:
        raise SystemExit("ABORT: no R_68K_32 at .text+0x%x" % LEA_RELOC)
    _, si, _, ad = rt[LEA_RELOC]
    tsec, toff, tname, tglob = e.target(si, ad)
    if tsec != ".data" or not tname:
        raise SystemExit("ABORT: the table the lea names is not a named .data symbol (%s %s)" % (tsec, tname))
    dr = e.rela(".rela.data")
    data = e.sec[".data"]["offset"]
    rows = []
    for r in range(bound + 1):
        at = toff + r * ROW
        ident = u32(e.b, data + at)
        q, n = dr.get(at + 4), dr.get(at + 8)
        if q is None or n is None or q[2] != R_68K_32 or n[2] != R_68K_32:
            raise SystemExit("ABORT: row %d of %s lacks its two R_68K_32 relocations" % (r, tname))
        rows.append((ident, e.target(q[1], q[3]), e.target(n[1], n[3])))
    return tname, bound, rows, rt


def cmd_gen(base, out_s, out_syms):
    e = Elf(base)
    tname, bound, rows, rt = read_table(e)
    if tname == NEW_TABLE:
        raise SystemExit("ABORT: %s already names %s -- this pass has run on it" % (base, NEW_TABLE))
    ids = [r[0] for r in rows]
    for ident, _ in NEW_ROWS:
        if ident in ids:
            raise SystemExit("ABORT: %s already has a row for 0x%08x" % (tname, ident))
    # sd.o's static controller array, from the relocation each accessor's lea carries.
    qt = set()
    for site in QUEUE_LEAS:
        if e.text(site, 2) != b"\x41\xf9" or (site + 2) not in rt:
            raise SystemExit("ABORT: .text+0x%x is not sd's relocated `lea queue,%%a0`" % site)
        _, si, typ, ad = rt[site + 2]
        sec, off, _, _ = e.target(si, ad)
        qt.add((sec, off))
    if len(qt) != 1 or next(iter(qt))[0] != ".bss":
        raise SystemExit("ABORT: sd's three accessors do not agree on one .bss array: %s" % sorted(qt))
    qsec, qoff = next(iter(qt))
    syms = ["--add-symbol", "sd_queue_tbl=.bss:0x%x,object,global" % qoff]
    lines = ["| %s -- generated by src/a4091_sd_rows.py from %s; not a source file." % (out_s.split("/")[-1], base.split("/")[-1]),
             "| Rows 0-%d reproduce %s by relocation; the last two register the A4091 and the A4092." % (bound, tname),
             "", "\t.data", "\t.balign 4", "\t.globl\t%s" % NEW_TABLE, "%s:" % NEW_TABLE]
    for r, (ident, q, n) in enumerate(rows):
        qsec_, qoff_, qname, qglob = q
        if qsec_ != ".text":
            raise SystemExit("ABORT: row %d's queue pointer is not in .text (%s)" % (r, qsec_))
        if not qglob:
            qname = "a4091_sdrow%d_q" % r
            syms += ["--add-symbol", "%s=.text:0x%x,function,global" % (qname, qoff_)]
        nsec, noff, _, _ = n
        if nsec not in (".data", ".text"):
            raise SystemExit("ABORT: row %d's name is not in .data or .text (%s)" % (r, nsec))
        nname = "a4091_sdrow%d_name" % r
        syms += ["--add-symbol", "%s=%s:0x%x,object,global" % (nname, nsec, noff)]
        lines.append("\t.long\t0x%08x, %s, %s" % (ident, qname, nname))
    for k, (ident, label) in enumerate(NEW_ROWS):
        lines.append("\t.long\t0x%08x, a4091queue, La4k_nm%d" % (ident, k))
    lines += ["La4k_end:", "\t.size\t%s, La4k_end-%s" % (NEW_TABLE, NEW_TABLE)]
    for k, (ident, label) in enumerate(NEW_ROWS):
        lines.append("La4k_nm%d:\t.asciz\t\"%s\"" % (k, label))
    lines += ["\t.balign 4", ""]
    open(out_s, "w").write("\n".join(lines))
    open(out_syms, "w").write("\n".join(syms) + "\n")
    print("      %s: %d rows (bound %d) -> %s: %d rows" % (tname, bound + 1, bound, NEW_TABLE, bound + 1 + len(NEW_ROWS)))
    for r, (ident, q, n) in enumerate(rows):
        print("        row %d  0x%08x  %s" % (r, ident, q[2] or "(local @.text+0x%x)" % q[1]))
    for k, (ident, label) in enumerate(NEW_ROWS):
        print("        row %d  0x%08x  a4091queue  \"%s\"  (new)" % (bound + 1 + k, ident, label))
    print("      sd's controller array: %s+0x%x -> sd_queue_tbl" % (qsec, qoff))


def cmd_patch(kernel, oldtable):
    e = Elf(kernel)
    rt = e.rela(".rela.text")
    o, si, typ, ad = rt[LEA_RELOC]
    cur = e.sym(si)["name"]
    want_rows = None
    newidx = e.index(NEW_TABLE)
    # the new table's row count, from its size
    s = e.sym(newidx)
    size = u32(e.b, e.syo + newidx * e.sye + 8)
    if size == 0 or size % ROW:
        raise SystemExit("ABORT: %s has size %d, not a whole number of rows" % (NEW_TABLE, size))
    want_rows = size // ROW
    newbound = want_rows - 1
    t = e.sec[".text"]["offset"] + BOUND_SITE
    bound = e.b[t + 1]
    if cur == NEW_TABLE and bound == newbound:
        print("  [skip] lea @0x%x already -> %s; bound already %d" % (LEA_RELOC, NEW_TABLE, bound))
        return
    if cur != oldtable or ad != 0 or typ != R_68K_32:
        raise SystemExit("ABORT: lea @0x%x names %s+%d, expected %s" % (LEA_RELOC, cur, ad, oldtable))
    if e.b[t] != 0x72 or bound != newbound - len(NEW_ROWS):
        raise SystemExit("ABORT: bound @0x%x is %02x %02x, expected moveq #%d"
                         % (BOUND_SITE, e.b[t], bound, newbound - len(NEW_ROWS)))
    struct.pack_into(">I", e.b, o + 4, (newidx << 8) | R_68K_32)
    e.b[t + 1] = newbound
    open(kernel, "wb").write(e.b)
    print("  [ok]   lea @0x%x  %s -> %s" % (LEA_RELOC, oldtable, NEW_TABLE))
    print("  [ok]   bound @0x%x  moveq #%d -> #%d (%d rows)" % (BOUND_SITE, bound, newbound, want_rows))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["gen"] and len(a) == 4:
        cmd_gen(a[1], a[2], a[3])
    elif a[:1] == ["patch"] and len(a) == 3:
        cmd_patch(a[1], a[2])
    else:
        raise SystemExit("usage: a4091_sd_rows.py gen BASE OUT.s OUT.syms | patch KERNEL OLDTABLE")
