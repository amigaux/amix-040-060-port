#!/usr/bin/env python3
# patch_cdfs_vfssw.py -- give RFS's vfssw row to cdfs, and guard rfsys, by three relocation
# retargets (2026-10-02, PO-02).  Run by relink-040-cdfs.sh after its link; src/cdfs_glue040.s
# explains the row and the guard, KNOWN-ISSUES DRIVER-LINE-3 records the proof.
#
#   .rela.data  vfssw+0x40  row 4 vsw_name   "rfs" (local string)  -> cdfs_vsw_name
#   .rela.data  vfssw+0x44  row 4 vsw_init   rf_init               -> cdfsinit
#   .rela.data  sysent+0x274  sysent[78] call  rfsys               -> cdfs_rfsys
#
# THE PROOF, asserted on the bytes before anything is written (and again on every run):
#   * vfssw is 12 rows of 16 bytes in .data and nfstype is 12, so row 4 is .data vfssw+0x40.
#   * Row 4 is RFS's and has the shape cdfs needs: name "rfs", init rf_init, vsw_vfsops and
#     vsw_flag 0 with no relocation (rf_init fills the ops at boot; cdfsinit will).
#   * NOTHING INDEXES ROW 4.  Every relocation in the image that lands inside vfssw is listed by
#     offset into the table.  Code reaches the table only at its base (addend 0: the walks and the
#     fstype-indexed lookups in mount, sysfs, statvfs, sync, vfs_getvfssw, vfs_mountroot, ...)
#     plus vfsinit's one store to row 0's vsw_vfsops (+8).  Any other offset aborts -- above all
#     one inside row 4 other than the row's own two pointers.
#   * rf_init is referenced only by row 4, and rfsys only by sysent[78], so the two retargets take
#     every route in.
# The table offset and order are what put cdfs's mountroot after ufs's (row 2): vfs_mountroot
# tries rows 1..nfstype-1 in order, and cdfs_mountroot answers EROFS anyway.
#
# All three or none; idempotent.

import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from a4091_sd_rows import Elf, u32, R_68K_32

ROW, ROWS, RFS_ROW = 16, 12, 4
SYS_RFSYS = 78
SYSENT_ROW = 8                     # { char narg; char flags; short pad; int (*call)(); }


def symval(e, name, sec):
    i = e.index(name)
    s = e.sym(i)
    if e.names[s["shndx"]] != sec:
        raise SystemExit("ABORT: %s is in %s, not %s" % (name, e.names[s["shndx"]], sec))
    return i, s["value"], u32(e.b, e.syo + i * e.sye + 8)


def cstr(e, sec, off):
    o = e.sec[sec]["offset"] + off
    return bytes(e.b[o:e.b.index(b"\0", o)])


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_cdfs_vfssw.py KERNEL")
    kernel = sys.argv[1]
    e = Elf(kernel)
    _, vfssw, vsize = symval(e, "vfssw", ".data")
    _, nfo, _ = symval(e, "nfstype", ".data")
    nf = u32(e.b, e.sec[".data"]["offset"] + nfo)
    if vsize != ROW * ROWS or nf != ROWS:
        raise SystemExit("ABORT: vfssw is %d bytes and nfstype %d -- not the 12-row table this was "
                         "proven against" % (vsize, nf))
    _, sysent, _ = symval(e, "sysent", ".data")
    rd = e.rela(".rela.data")
    name_at, init_at = vfssw + RFS_ROW * ROW, vfssw + RFS_ROW * ROW + 4
    call_at = sysent + SYS_RFSYS * SYSENT_ROW + 4
    data = e.sec[".data"]["offset"]

    # ---- row 4, as it stands
    for k in (8, 12):
        if (vfssw + RFS_ROW * ROW + k) in rd or u32(e.b, data + vfssw + RFS_ROW * ROW + k):
            raise SystemExit("ABORT: vfssw[4] +%d is not a plain 0" % k)

    def tgt(at):
        if at not in rd:
            raise SystemExit("ABORT: no .rela.data record at .data+0x%x" % at)
        o, si, typ, ad = rd[at]
        if typ != R_68K_32 or ad != 0 and e.sym(si)["info"] & 0xF != 3:
            raise SystemExit("ABORT: .data+0x%x: type %d addend %d" % (at, typ, ad))
        return o, si, e.target(si, ad)

    _, _, nt = tgt(name_at)
    _, _, it = tgt(init_at)
    _, _, ct = tgt(call_at)
    state = (nt[2] == "cdfs_vsw_name", it[2] == "cdfsinit", ct[2] == "cdfs_rfsys")
    if all(state):
        print("  [skip] vfssw[4] is already cdfs and sysent[78] already cdfs_rfsys")
    elif any(state):
        raise SystemExit("ABORT: a partial earlier run: %s" % (state,))
    else:
        if cstr(e, nt[0], nt[1]) != b"rfs" or it[2] != "rf_init" or ct[2] != "rfsys":
            raise SystemExit("ABORT: vfssw[4] is %r/%s and sysent[78] %s -- not RFS's row and rfsys"
                             % (cstr(e, nt[0], nt[1]), it[2], ct[2]))
        print("  vfssw[4] = { \"rfs\", rf_init, 0, 0 }; sysent[78] = rfsys")

    # ---- the census: every relocation that lands inside vfssw
    lands = {}
    refs = {"rf_init": [], "rfsys": [], "cdfsinit": [], "cdfs_rfsys": []}
    for secname in [n for n in e.names if n.startswith(".rela")]:
        for at, (o, si, typ, ad) in e.rela(secname).items():
            sec, off, name, _ = e.target(si, ad)
            if name in refs:
                refs[name].append((secname, at))
            if sec == ".data" and vfssw <= off < vfssw + vsize:
                lands.setdefault(off - vfssw, []).append((secname, at))
    allowed = {0, 8}
    bad = {k: v for k, v in lands.items() if k not in allowed}
    if bad:
        raise SystemExit("ABORT: relocations land inside vfssw at %s -- something indexes a row"
                         % {hex(k): [(s, hex(a)) for s, a in v] for k, v in bad.items()})
    if len(lands.get(8, [])) != 1 or lands[8][0][0] != ".rela.text":
        raise SystemExit("ABORT: vfssw+8 is reached by %s, expected vfsinit's one store" % lands.get(8))
    print("  census: %d relocation(s) reach vfssw at its base, 1 at +8 (row 0's ops); none inside "
          "row 4" % len(lands.get(0, [])))
    # Data references: the table and sysent are the only ways in.  Code references: nothing calls
    # rf_init directly, and the one call of rfsys is the glue's own tail-jump.
    done = all(state)
    want_data = {"rf_init": [] if done else [init_at], "cdfsinit": [init_at] if done else [],
                 "rfsys": [] if done else [call_at], "cdfs_rfsys": [call_at] if done else []}
    _, gl, gsz = symval(e, "cdfs_rfsys", ".text")
    for name, want in want_data.items():
        got = sorted(a for s, a in refs[name] if s == ".rela.data")
        if got != want:
            raise SystemExit("ABORT: %s is referenced from .data at %s, expected %s"
                             % (name, [hex(a) for a in got], [hex(a) for a in want]))
    code = {n: [a for s, a in refs[n] if s == ".rela.text"] for n in refs}
    if code["rf_init"] or code["cdfsinit"] or code["cdfs_rfsys"]:
        raise SystemExit("ABORT: code references rf_init/cdfsinit/cdfs_rfsys directly: %s" % code)
    if len(code["rfsys"]) != 1 or not gl <= code["rfsys"][0] < gl + 0x20:
        raise SystemExit("ABORT: rfsys is called from code at %s, expected only cdfs_rfsys's jmp"
                         % [hex(a) for a in code["rfsys"]])
    print("  rf_init is reached only through vfssw[4], rfsys only through sysent[78] "
          "(and cdfs_rfsys's own jmp)")
    if all(state):
        return

    # ---- the three retargets
    for at, new in ((name_at, "cdfs_vsw_name"), (init_at, "cdfsinit"), (call_at, "cdfs_rfsys")):
        o = rd[at][0]
        struct.pack_into(">I", e.b, o + 4, (e.index(new) << 8) | R_68K_32)
        struct.pack_into(">i", e.b, o + 8, 0)
        print("  [ok]   .data+0x%x -> %s" % (at, new))
    open(kernel, "wb").write(e.b)
    print("vfssw[4] = { \"cdfs\", cdfsinit, 0, 0 }; sysent[78] = cdfs_rfsys -> %s" % kernel)


main()
