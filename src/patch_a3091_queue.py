#!/usr/bin/env python3
# patch_a3091_queue.py -- route the A3091 driver's start-queue calls through the lifecycle
# wrappers of src/a3091q040.s by retargeting seven call relocations (2026-10-02).
#
#   .rela.text @0xcfbe 0xd1b4 0xd1d4 0xd2ea   uqueue (local, 0xcfce)        -> a3091q_uqueue
#   .rela.text @0xd002 0xd356                 startany (local, 0xd00c)      -> a3091q_startany
#   .rela.text @0xd21a                        dma_a3091_startdma_reconn     -> a3091q_resume
#
# The four uqueue sites are a3091queue's and DFA cases 0, 2 and 5; the two startany sites are
# the one inside uqueue and the IDLE tail cases 0, 5 and 7 share; 0xd21a is case 3's re-arm,
# which patch_a3091_dma.py (the base link) already pointed at Antti's B2 wrapper -- a3091q_resume
# tail-jumps there, so B2 still runs exactly once per resume.
#
# uqueue and startany are file-statics, and the stock kernel has three same-named copies of
# a3091.c's neighbours (A2090, A2091), so nothing here goes by name alone: a site must name a
# symbol with that name AND the a3091 value, and the census below must find exactly these sites
# -- a relocation to a3091's uqueue or startany that is not in the list aborts the run, so a
# new call site cannot be left unguarded silently.  The bytes before every site must be a
# `jsr (abs.l)`.  Only r_info's symbol index changes; addends and .text bytes are untouched.
#
# All seven or none.  Idempotent: a second run reports seven skips and writes the same bytes.
#
#   --off   also stamp a3q_on = 0, the control kernel: every wrapper becomes a plain tail-jump
#           to the stock body, and the image differs from the fixed one in that word alone.
#
# Run after `ld -r` has linked build/a3091q040.o (relink-040-a3091q.sh).

import struct, sys

argv = [a for a in sys.argv[1:] if not a.startswith("--")]
OFF = "--off" in sys.argv[1:]
KERNEL = argv[0] if argv else "build/unix-040-a3091q"
R_68K_32 = 1
JSR_ABS_L = 0x4eb9

UQUEUE_VALUE = 0xcfce
STARTANY_VALUE = 0xd00c
SITES = {
    0xcfbe: ("uqueue", UQUEUE_VALUE, "a3091q_uqueue"),      # a3091queue, first command
    0xd1b4: ("uqueue", UQUEUE_VALUE, "a3091q_uqueue"),      # case 0, more commands queued
    0xd1d4: ("uqueue", UQUEUE_VALUE, "a3091q_uqueue"),      # case 2, the pre-empted unit
    0xd2ea: ("uqueue", UQUEUE_VALUE, "a3091q_uqueue"),      # case 5, more commands queued
    0xd002: ("startany", STARTANY_VALUE, "a3091q_startany"),  # inside uqueue, empty queue
    0xd356: ("startany", STARTANY_VALUE, "a3091q_startany"),  # the IDLE tail of 0, 5 and 7
    0xd21a: ("dma_a3091_startdma_reconn", None, "a3091q_resume"),  # case 3, the resume
}


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff = u32(b, 32); e_shentsize = u16(b, 46); e_shnum = u16(b, 48); e_shstrndx = u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(dict(name=u32(b, o), offset=u32(b, o + 16), size=u32(b, o + 20),
                       link=u32(b, o + 24), entsize=u32(b, o + 36)))
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = b.index(b"\0", shstr + s["name"]); return b[shstr + s["name"]:e].decode()

    names = [nm(s) for s in sh]
    byname = {n: s for n, s in zip(names, sh)}
    symtab = byname[".symtab"]; strtab = sh[symtab["link"]]
    so, se = symtab["offset"], symtab["entsize"]; sn = symtab["size"] // se
    stroff = strtab["offset"]

    def symname(i):
        o = so + i * se; n = u32(b, o); e = b.index(b"\0", stroff + n); return b[stroff + n:e].decode()

    def sym_value(i): return u32(b, so + i * se + 4)
    def sym_shndx(i): return u16(b, so + i * se + 14)

    def sym_index(name):
        found = [i for i in range(sn) if symname(i) == name]
        if len(found) != 1:
            raise SystemExit("ABORT: %d symbols named %s (want exactly one -- was "
                             "build/a3091q040.o ld -r'd in?)" % (len(found), name))
        return found[0]

    text_ndx = names.index(".text")
    text = byname[".text"]["offset"]
    for site in SITES:
        op = u16(b, text + site - 2)
        if op != JSR_ABS_L:
            raise SystemExit("ABORT: .text 0x%x is 0x%04x, not jsr (abs.l) -- a3091.c is not where "
                             "this patch was verified" % (site - 2, op))

    rela = byname[".rela.text"]
    ro, re_ = rela["offset"], rela["entsize"]; rn = rela["size"] // re_
    at = {}
    census = {"uqueue": [], "startany": []}
    for i in range(rn):
        o = ro + i * re_
        roff = u32(b, o); info = u32(b, o + 4); s = info >> 8
        at[roff] = o
        n = symname(s)
        for name, value in (("uqueue", UQUEUE_VALUE), ("startany", STARTANY_VALUE)):
            if n == name and sym_value(s) == value and sym_shndx(s) == text_ndx:
                census[name].append(roff)
    for name, want in (("uqueue", UQUEUE_VALUE), ("startany", STARTANY_VALUE)):
        expect = sorted(s for s, v in SITES.items() if v[0] == name)
        got = sorted(census[name])
        done_already = [s for s in expect if s not in got]
        unlisted = [s for s in got if s not in expect]
        if unlisted:
            raise SystemExit("ABORT: a3091's %s (0x%x) is also called at %s -- a call site this "
                             "patch does not guard" % (name, want, [hex(x) for x in unlisted]))
        print("  census: %s@0x%x called at %d listed site(s), %d already retargeted"
              % (name, want, len(got), len(done_already)))

    done = skip = 0
    for site, (old, value, new) in sorted(SITES.items()):
        if site not in at:
            raise SystemExit("ABORT: no .rela.text record at 0x%x" % site)
        o = at[site]
        info = u32(b, o + 4); cur = info >> 8; typ = info & 0xff
        if typ != R_68K_32:
            raise SystemExit("ABORT @0x%x: relocation type %d != R_68K_32" % (site, typ))
        if u32(b, o + 8) != 0:
            raise SystemExit("ABORT @0x%x: addend 0x%x != 0" % (site, u32(b, o + 8)))
        tgt = sym_index(new)
        if cur == tgt:
            print("  [skip] .text 0x%x already -> %s" % (site, new))
            skip += 1
            continue
        if symname(cur) != old or (value is not None and sym_value(cur) != value):
            raise SystemExit("ABORT @0x%x: current target %s (0x%x), expected %s%s"
                             % (site, symname(cur), sym_value(cur), old,
                                "" if value is None else " (0x%x)" % value))
        struct.pack_into(">I", b, o + 4, (tgt << 8) | R_68K_32)
        print("  [ok]   .text 0x%x  %s -> %s" % (site, old, new))
        done += 1
    if done and skip:
        raise SystemExit("ABORT: partial retarget (%d done, %d already) -- the seven are atomic"
                         % (done, skip))

    on_i = sym_index("a3q_on")
    if names[sym_shndx(on_i)] != ".data":
        raise SystemExit("ABORT: a3q_on is not in .data")
    on_off = byname[".data"]["offset"] + sym_value(on_i)
    on = u32(b, on_off)
    magic = u32(b, byname[".data"]["offset"] + sym_value(sym_index("a3q_magic")))
    if magic != 0x41335121:
        raise SystemExit("ABORT: a3q_magic reads 0x%08x, not \"A3Q!\"" % magic)
    if OFF:
        if on not in (0, 1):
            raise SystemExit("ABORT: a3q_on reads 0x%x, expected 1 or 0" % on)
        struct.pack_into(">I", b, on_off, 0)
        print("  [off]  a3q_on 1 -> 0: the CONTROL kernel (wrappers tail-jump to stock)")
    elif on != 1:
        raise SystemExit("ABORT: a3q_on reads 0x%x -- a control base; rebuild without --off" % on)

    open(KERNEL, "wb").write(b)
    print("a3091 start queue: lifecycle wrappers %s -> %s" % ("OFF (control)" if OFF else "on", KERNEL))


# Guarded: fsobj-patch.py and other readers load this file for its site tables, and an
# unguarded main() would patch whatever kernel path sits in their argv (2026-10-30).
if __name__ == "__main__":
    main()
