#!/usr/bin/env python3
# patch_trapdiag_off.py -- take the user-trap diagnostics off the trap path, without moving a byte of layout.
#
# `utraps` (inside nullvect_orig, .text 0x11ea) calls the user-trap handler from the site at 0x11ee, relocation at
# 0x11f0.  Stock names `u_trap` there.  The ISSUE-106 latch (src/patch_srgtrap.py) pointed it at `srg_utraps`, and
# the F4 vector-dispatch census (src/patch_kvecdisp.py, relink-040-f6.sh --kvd) at `kvd_utraps`, which tail-jumps
# to srg_utraps, which tail-jumps to u_trap.  Both ran on every system call and user fault: about 43 uncached
# accesses (~11 us on the 68LC060).  This points the relocation back at `u_trap`, so neither runs, and sets the
# census's runtime switch `kvd_on` to 0, so a later re-chain starts with the census out of its own path.  The
# objects stay linked and every address stays where it was: the image differs from its input in the one
# relocation's symbol and the one .data word.
#
# Refusals, all fail-closed:
#   1. no relocation at 0x11f0, or not R_68K_32, or a nonzero addend  -> not the call operand this was measured on
#   2. the relocation names something other than kvd_utraps, srg_utraps or u_trap  -> unknown chain
#   3. u_trap not defined                                            -> nothing to point at
#   4. kvd_on present but not a .data longword holding 0 or 1          -> not the census's switch
# A target already u_trap with kvd_on 0 (or absent) is a skip.  Usage: python3 patch_trapdiag_off.py <image>
import struct
import sys

RELOC = 0x000011F0
CHAIN = ("kvd_utraps", "srg_utraps")
TARGET = "u_trap"
SWITCH = "kvd_on"
R_68K_32 = 1


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main(img):
    buf = bytearray(open(img, "rb").read())
    e_shoff, e_shentsize = u32(buf, 32), u16(buf, 46)
    e_shnum, e_shstrndx = u16(buf, 48), u16(buf, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(buf, o), "offset": u32(buf, o + 16), "size": u32(buf, o + 20),
                   "link": u32(buf, o + 24), "entsize": u32(buf, o + 36)})
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = buf.index(b"\0", shstr + s["name"])
        return buf[shstr + s["name"]:e].decode()

    names = [nm(s) for s in sh]
    secs = dict(zip(names, sh))
    rela = secs[".rela.text"]
    symtab = sh[rela["link"]]
    strtab = sh[symtab["link"]]
    nsyms = symtab["size"] // symtab["entsize"]

    def sym(i):
        o = symtab["offset"] + i * symtab["entsize"]
        n = u32(buf, o)
        e = buf.index(b"\0", strtab["offset"] + n)
        return buf[strtab["offset"] + n:e].decode(), u32(buf, o + 4), u16(buf, o + 14)

    index = {}
    for i in range(nsyms):
        name, value, shndx = sym(i)
        if name and shndx != 0 and name not in index:
            index[name] = (i, value, shndx)

    if TARGET not in index:
        raise SystemExit("ABORT: %s not defined" % TARGET)
    target_idx = index[TARGET][0]

    site = None
    for i in range(rela["size"] // rela["entsize"]):
        o = rela["offset"] + i * rela["entsize"]
        if u32(buf, o) == RELOC:
            site = o
            break
    if site is None:
        raise SystemExit("ABORT: relocation @0x%x not found (base drifted?)" % RELOC)
    r_info, addend = u32(buf, site + 4), u32(buf, site + 8)
    if (r_info & 0xFF) != R_68K_32 or addend != 0:
        raise SystemExit("ABORT: reloc @0x%x type %d addend 0x%x, expected R_68K_32 + 0"
                         % (RELOC, r_info & 0xFF, addend))
    cur = sym(r_info >> 8)[0]
    if cur not in CHAIN + (TARGET,):
        raise SystemExit("ABORT: reloc @0x%x names %r, expected one of %s" % (RELOC, cur, CHAIN + (TARGET,)))

    sw = None
    if SWITCH in index:
        _, value, shndx = index[SWITCH]
        if shndx >= len(names) or names[shndx] != ".data":
            raise SystemExit("ABORT: %s is not a .data symbol" % SWITCH)
        sw = secs[".data"]["offset"] + value
        if u32(buf, sw) not in (0, 1):
            raise SystemExit("ABORT: %s holds 0x%x, expected 0 or 1" % (SWITCH, u32(buf, sw)))

    changed = []
    if cur != TARGET:
        struct.pack_into(">I", buf, site + 4, (target_idx << 8) | R_68K_32)
        changed.append("reloc @0x%x %s -> %s" % (RELOC, cur, TARGET))
    if sw is not None and u32(buf, sw) != 0:
        struct.pack_into(">I", buf, sw, 0)
        changed.append("%s 1 -> 0 (.data+0x%x)" % (SWITCH, index[SWITCH][1]))
    if not changed:
        print("  [skip] user-trap diagnostics already off the trap path")
        return
    open(img, "wb").write(buf)
    for c in changed:
        print("  [ok]   %s" % c)
    print("  [ok]   utraps calls u_trap directly: no census, no ring")


# Guarded: tools load patch_*.py files for their tables, and an unguarded main() would patch their argv.
if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/unix-040")
