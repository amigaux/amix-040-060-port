#!/usr/bin/env python3
# ide_sd_rows.py -- the sd.c side of the Gayle IDE registration on the driver line (2026-10-02,
# P-15 P2).  Run by relink-040-ide.sh on either side of its link; src/ide_sd_glue040.s explains
# the mechanism and the order rule.
#
#   gen BASE OUT.s OUT.syms   the base's controller table, every existing row by relocation, then
#                             one row: IDE_SD_ID on idequeue.  The generator is a4091_sd_rows.py's,
#                             with this pass's table name, row and symbol prefix.
#   patch KERNEL OLDTABLE [--order address]
#                             after the link: init()'s `lea <table>,%a3` -> ide_scsicard and its
#                             loop bound (a4091_sd_rows.py patch), then init()'s `jsr autocon`
#                             relocation at .text 0xd78e -> ide_sd_autocon.  --order address
#                             stamps ide_sd_key = 0 (IDE ranks by its real base, card 0).
#
# All edits are asserted against the bytes first and are idempotent; the autocon retarget refuses
# a site that names anything but autocon or ide_sd_autocon, so a pass that wraps that call too
# fails closed here instead of being bypassed.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import a4091_sd_rows as rows

IDE_SD_ID = 0x1de0a400            # must equal the cmpl immediate in src/ide_sd_glue040.s
NEW_TABLE = "ide_scsicard"
NEW_ROWS = [(IDE_SD_ID, "A4000 IDE")]
AUTOCON_SITE, AUTOCON_RELOC = 0xD78C, 0xD78E    # init(): `jsr autocon` and its operand
KEY_DEFAULT = 0xfffffff0


def cmd_gen(base, out_s, out_syms):
    rows.cmd_gen(base, out_s, out_syms, new_table=NEW_TABLE, new_rows=NEW_ROWS,
                 queue_fn="idequeue", prefix="ide", label="Lide", queue_tbl=False,
                 what="the A4000's Gayle IDE port")


def cmd_patch(kernel, oldtable, order):
    rows.cmd_patch(kernel, oldtable, new_table=NEW_TABLE, nnew=len(NEW_ROWS))
    e = rows.Elf(kernel)
    if e.text(AUTOCON_SITE, 2) != b"\x4e\xb9":
        raise SystemExit("ABORT: .text+0x%x is not `jsr (abs.l)` -- init() is not where this was verified"
                         % AUTOCON_SITE)
    # the glue's id must be the row's id
    glue = e.index("ide_sd_autocon")
    gs = e.sym(glue)
    t = e.sec[".text"]["offset"] + gs["value"]
    if bytes(e.b[t:t + 2]) != b"\x0c\xaf" or rows.u32(e.b, t + 2) != IDE_SD_ID:
        raise SystemExit("ABORT: ide_sd_autocon does not open with cmpl #0x%08x,%%sp@(4)" % IDE_SD_ID)
    rt = e.rela(".rela.text")
    if AUTOCON_RELOC not in rt:
        raise SystemExit("ABORT: no .rela.text record at 0x%x" % AUTOCON_RELOC)
    o, si, typ, ad = rt[AUTOCON_RELOC]
    cur = e.sym(si)["name"]
    if typ != rows.R_68K_32 or ad != 0:
        raise SystemExit("ABORT @0x%x: type %d addend %d" % (AUTOCON_RELOC, typ, ad))
    if cur == "ide_sd_autocon":
        print("  [skip] jsr @0x%x already -> ide_sd_autocon" % AUTOCON_SITE)
    elif cur == "autocon":
        struct.pack_into(">I", e.b, o + 4, (glue << 8) | rows.R_68K_32)
        print("  [ok]   jsr @0x%x  autocon -> ide_sd_autocon" % AUTOCON_SITE)
    else:
        raise SystemExit("ABORT @0x%x: init()'s autocon call names %s -- another pass wraps it"
                         % (AUTOCON_RELOC, cur))
    ks = e.sym(e.index("ide_sd_key"))
    if e.names[ks["shndx"]] != ".data":
        raise SystemExit("ABORT: ide_sd_key is not in .data")
    ko = e.sec[".data"]["offset"] + ks["value"]
    key = rows.u32(e.b, ko)
    want = 0 if order == "address" else KEY_DEFAULT
    if key not in (0, KEY_DEFAULT):
        raise SystemExit("ABORT: ide_sd_key reads 0x%08x" % key)
    if key != want:
        struct.pack_into(">I", e.b, ko, want)
    print("  [ok]   ide_sd_key = 0x%08x (%s)" % (want, "rank by the real base: IDE is card 0"
          if want == 0 else "after every real board: IDE takes the next free card"))
    open(kernel, "wb").write(e.b)


if __name__ == "__main__":
    a = sys.argv[1:]
    order = "after"
    if "--order" in a:
        i = a.index("--order")
        order = a[i + 1]
        del a[i:i + 2]
        if order not in ("after", "address"):
            raise SystemExit("--order after|address")
    if a[:1] == ["gen"] and len(a) == 4:
        cmd_gen(a[1], a[2], a[3])
    elif a[:1] == ["patch"] and len(a) == 3:
        cmd_patch(a[1], a[2], order)
    else:
        raise SystemExit("usage: ide_sd_rows.py gen BASE OUT.s OUT.syms | patch KERNEL OLDTABLE [--order after|address]")
