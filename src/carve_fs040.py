#!/usr/bin/env python3
# carve_fs040.py -- take ufs and s5 out of a k46 base, dead and zeroed in place (amix-dlm S5-11,
# contract C4-6; 2026-10-27).  Run by relink-040-carve.sh on relink-040.sh's output.
#
# A module kernel of this line loads ufs as a core-tier module (amix-dlm tools/carve.py wraps the
# stock object as tools/fsobj-patch.py patches it for 4 KiB pages); s5 has no k46 module (amix-dlm
# S5-37).  So the base keeps neither.  The objects' bytes stay where they are and nothing moves:
# every fixed-address pass of this port addresses the base by offset, and many of them lie past
# the ufs range.  Instead, in the base:
#
#   1. the ranges are found from the stock objects (fs/ufs/exp, fs/s5/exp): their .text and .data
#      lie whole in the stock kernel, at the one place where the bytes and every relocation match,
#      and the base keeps the stock relocations there.  The object markers agree: the base's run
#      of STT_FILE groups that is the object's own (exp, then its .c files) holds exactly the
#      local symbols in the ranges, and the globals defined there are the object's globals.  The
#      object's local .bss is placed by its local .bss symbols;
#   2. the in-references go: vfssw loses the rows whose vsw_init is the object's (ufsinit,
#      s5init), the later rows move up and nfstype drops by the rows taken; init_tbl loses the
#      entry that calls into a range (s5's inoinit), the later entries move up;
#   3. the relocations inside the ranges are dropped, and the bytes of the .text and .data
#      ranges zeroed;
#   4. every symbol defined in the ranges leaves the symbol table, locals and markers included,
#      so nothing can bind to them and no name points into the zeros; so do the COMMONs only the
#      ranges use (ihead, inode, hinode, ...: the modules allocate their own).
#
# Gates, each refusing:
#   A. no relocation outside the ranges reaches into them, before the edit (except the vfssw and
#      init_tbl entries of step 2) and after it (none at all), and none names a removed symbol;
#   B. the private COMMONs are gone from the symbol table, and with --core-list they are exactly
#      the objects' COMMONs less the core tier (amix-dlm abi/k46/core.list);
#   C. with --core-list, every name of the core tier is still a global of the output, defined or
#      COMMON: the modules import them from the base;
#   D. outside the ranges, vfssw, nfstype and init_tbl, .text and .data are the input's bytes, and
#      every relocation there is the input's.
#
# Usage: python3 carve_fs040.py --stock UNIX --obj ufs=EXP --obj s5=EXP [--core-list LIST] BASE OUT
#        python3 carve_fs040.py --check [--core-list LIST] OUT     (B and C, and no vfssw row,
#                                                                   symbol or COMMON of ufs or s5)

import struct
import sys

SHN_UNDEF, SHN_ABS, SHN_COMMON = 0, 0xFFF1, 0xFFF2
STT_SECTION, STT_FILE = 3, 4
SHT_SYMTAB, SHT_RELA, SHT_NOBITS = 2, 4, 8
VFSSW_ROW = 16          # struct vfssw: vsw_name, vsw_init, vsw_vfsops, vsw_flag
INITS = {"ufs": "ufsinit", "s5": "s5init"}
OWN = ("ufsinit", "s5init", "ufs_mountroot", "s5mountroot", "inoinit", "ufs_vfsops", "s5vfsops")


def die(msg):
    raise SystemExit("carve_fs040: " + msg)


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


class Elf(object):
    """An ELF32 big-endian relocatable object: sections, symbols, RELA entries; rewritable."""

    def __init__(self, path):
        b = self.b = open(path, "rb").read()
        if b[:4] != b"\x7fELF" or b[4] != 1 or b[5] != 2 or u16(b, 16) != 1:
            die("%s is not an ELF32 big-endian relocatable object" % path)
        so, se, sn, ss = u32(b, 32), u16(b, 46), u16(b, 48), u16(b, 50)
        self.sh = [list(struct.unpack(">10I", b[so + i * se:so + i * se + 40])) for i in range(sn)]
        st = self.sh[ss]
        self.names = [b[st[4] + s[0]:b.index(b"\0", st[4] + s[0])].decode() for s in self.sh]
        self.idx = {n: i for i, n in enumerate(self.names) if n}
        self.data = {i: bytearray(b[s[4]:s[4] + s[5]]) for i, s in enumerate(self.sh) if s[1] != SHT_NOBITS}
        self.symsec = [i for i, s in enumerate(self.sh) if s[1] == SHT_SYMTAB][0]
        strs = self.data[self.sh[self.symsec][6]]
        self.syms = []
        d = self.data[self.symsec]
        for o in range(0, len(d), 16):
            nm, val, size, info, other, shndx = struct.unpack(">IIIBBH", d[o:o + 16])
            self.syms.append(dict(name=strs[nm:strs.index(b"\0", nm)].decode("latin-1"), nm=nm, value=val,
                                  size=size, info=info, other=other, shndx=shndx))
        self.rela = {}          # target section index -> [[offset, symidx, type, addend]]
        for i, s in enumerate(self.sh):
            if s[1] == SHT_RELA:
                d = self.data[i]
                self.rela[s[7]] = [[u32(d, o), u32(d, o + 4) >> 8, u32(d, o + 4) & 0xFF,
                                    struct.unpack(">i", d[o + 8:o + 12])[0]] for o in range(0, len(d), 12)]

    def secname(self, shndx):
        return self.names[shndx] if 0 < shndx < len(self.names) else None

    def is_local(self, s):
        return s["info"] >> 4 == 0

    def glob(self):
        return {s["name"]: s for s in self.syms if not self.is_local(s) and s["name"]}

    def relocs(self, sec):
        """[(offset, type, symbol, addend)] of section sec; a section symbol is named by its section"""
        out = []
        for off, si, typ, add in self.rela.get(self.idx[sec], []):
            s = self.syms[si]
            out.append((off, typ, self.secname(s["shndx"]) if s["info"] & 0xF == STT_SECTION else s["name"], add))
        return out

    def write(self, path):
        """Write the object back with the edited section contents, symbols and relocations."""
        strs_i = self.sh[self.symsec][6]
        self.data[self.symsec] = bytearray(b"".join(
            struct.pack(">IIIBBH", s["nm"], s["value"], s["size"], s["info"], s["other"], s["shndx"])
            for s in self.syms))
        self.sh[self.symsec][7] = sum(1 for s in self.syms if self.is_local(s))
        for i, s in enumerate(self.sh):
            if s[1] == SHT_RELA:
                self.data[i] = bytearray(b"".join(struct.pack(">IIi", off, si << 8 | typ, add)
                                                  for off, si, typ, add in self.rela[s[7]]))
        assert strs_i in self.data
        out = bytearray(self.b[:52])
        order = sorted((i for i in range(1, len(self.sh))), key=lambda i: self.sh[i][4])
        for i in order:
            s = self.sh[i]
            if s[1] == SHT_NOBITS:
                s[4] = len(out)
                continue
            al = max(s[8], 1)
            out += b"\0" * (-len(out) % al)
            s[4], s[5] = len(out), len(self.data[i])
            out += self.data[i]
        out += b"\0" * (-len(out) % 4)
        struct.pack_into(">I", out, 32, len(out))
        for s in self.sh:
            out += struct.pack(">10I", *s)
        open(path, "wb").write(out)


def locate(U, O, sec, shifts):
    """Where O's section sits in U's: the one place its bytes and its relocations both match.  A
    relocation against a section symbol fixes that section's shift; shifts collects them."""
    ob, ub = bytes(O.data[O.idx[sec]]), bytes(U.data[U.idx[sec]])
    orl = {off: (t, n, a) for off, t, n, a in O.relocs(sec)}
    url = {off: (t, n, a) for off, t, n, a in U.relocs(sec)}
    found = []
    at = ub.find(ob)
    while at >= 0:
        sh = dict(shifts)
        sh.setdefault(sec, at)
        ok = sh[sec] == at and sum(1 for off in url if at <= off < at + len(ob)) == len(orl)
        for off, (t, n, add) in orl.items():
            u = url.get(at + off)
            if not ok or u is None or u[:2] != (t, n):
                ok = False
                break
            if n in (".text", ".data", ".bss"):
                sh.setdefault(n, u[2] - add)
                ok = u[2] - add == sh[n]
            else:
                ok = u[2] == add
        if ok:
            found.append(sh)
        at = ub.find(ob, at + 1)
    if len(found) != 1:
        die("%s of %s matches %d places of the stock kernel, not one" % (sec, O.path, len(found)))
    return found[0]


def file_groups(e):
    """[(file name, index of the STT_FILE symbol, [indices of the locals after it])], in order."""
    groups = []
    for i, s in enumerate(e.syms):
        if not e.is_local(s) or i == 0:
            continue
        if s["info"] & 0xF == STT_FILE:
            groups.append((s["name"], i, []))
        elif groups and s["info"] & 0xF != STT_SECTION:
            groups[-1][2].append(i)
    return groups


def ranges_of(fs, U, B, O):
    """The object's ranges in the base {section: (lo, hi)} and the indices of its symbols there."""
    O.path = fs
    shifts = locate(U, O, ".data", locate(U, O, ".text", {}))
    rng = {sec: (shifts[sec], shifts[sec] + len(O.data[O.idx[sec]])) for sec in (".text", ".data")}
    for sec, (lo, hi) in rng.items():
        ur = sorted(r for r in U.relocs(sec) if lo <= r[0] < hi)
        br = sorted(r for r in B.relocs(sec) if lo <= r[0] < hi)
        if ur != br:
            die("%s %s 0x%x-0x%x: the base's relocations are not the stock kernel's" % (fs, sec, lo, hi))
        if sec == ".data" and bytes(U.data[U.idx[sec]][lo:hi]) != bytes(B.data[B.idx[sec]][lo:hi]):
            die("%s .data 0x%x-0x%x differs between the stock kernel and the base" % (fs, lo, hi))
    # the object markers: the base's run of FILE groups that is the object's own
    want = [n for n, _, _ in file_groups(O)]
    have = file_groups(B)
    runs = [k for k in range(len(have) - len(want) + 1)
            if [n for n, _, _ in have[k:k + len(want)]] == want]
    if len(runs) != 1:
        die("%s: the object's %d file markers occur %d times in the base, not once" % (fs, len(want), len(runs)))
    run = have[runs[0]:runs[0] + len(want)]
    mine = set()
    for _, fi, members in run:
        mine.add(fi)
        mine.update(members)
    # the local .bss: placed by the object's local .bss symbols, matched by name in the run
    obss = O.idx.get(".bss")
    osz = O.sh[obss][5] if obss else 0
    if osz:
        ol = {s["name"]: s["value"] for s in O.syms if O.is_local(s) and s["shndx"] == obss and s["name"]}
        bl = {}
        for i in mine:
            s = B.syms[i]
            if B.secname(s["shndx"]) == ".bss":
                bl.setdefault(s["name"], []).append(s["value"])
        sh = {v - ol[n] for n in ol for v in bl.get(n, [])}
        if len(sh) != 1 or set(ol) != set(bl) or any(len(v) != 1 for v in bl.values()):
            die("%s: the object's local .bss does not place in the base (%d shifts)" % (fs, len(sh)))
        b0 = sh.pop()
        rng[".bss"] = (b0, b0 + osz)
    # every local of the run lies in a range, and every local symbol in a range is the run's
    for i in mine:
        s = B.syms[i]
        sec = B.secname(s["shndx"])
        if s["info"] & 0xF == STT_FILE:
            continue
        if sec not in rng or not rng[sec][0] <= s["value"] <= s["value"] + s["size"] <= rng[sec][1]:
            die("%s: the local %s of the object's markers lies outside its ranges" % (fs, s["name"]))
    gl = set()
    for i, s in enumerate(B.syms):
        sec = B.secname(s["shndx"])
        if sec in rng and rng[sec][0] <= s["value"] < rng[sec][1] and s["info"] & 0xF != STT_SECTION:
            if B.is_local(s):
                if i not in mine:
                    die("%s: the local %s @%s+0x%x is in the range, not of the object" % (fs, s["name"], sec, s["value"]))
            else:
                if s["value"] + s["size"] > rng[sec][1]:
                    die("%s: %s runs past the range's end" % (fs, s["name"]))
                gl.add(s["name"])
                mine.add(i)
    od = {s["name"] for s in O.syms if not O.is_local(s) and s["name"]
          and s["shndx"] not in (SHN_UNDEF, SHN_COMMON)}
    if gl != od:
        die("%s: the base's globals in the ranges are not the object's (%s)" % (fs, " ".join(sorted(gl ^ od))))
    return rng, mine, {s["name"] for s in O.syms if s["shndx"] == SHN_COMMON}


def inside(rng, sec, v):
    return any(sec in r and r[sec][0] <= v < r[sec][1] for r in rng)


def reaches(B, rng, gone, sec, off, si, add):
    """Does the relocation at sec+off reach into a range or name a removed symbol?"""
    s = B.syms[si]
    tsec = B.secname(s["shndx"])
    if s["info"] & 0xF == STT_SECTION:
        return inside(rng, tsec, add)
    return si in gone or (tsec is not None and (inside(rng, tsec, s["value"]) or inside(rng, tsec, s["value"] + add)))


def table(B, name, ent, drop_names, gone):
    """Drop the entries of the .data table `name` (entries of `ent` bytes) whose relocations name a
    removed symbol in drop_names; the later entries move up, the freed tail is zero.  Returns
    [(index, the dropped entry's symbols)]."""
    s = B.glob().get(name)
    if not s or B.secname(s["shndx"]) != ".data" or s["size"] % ent:
        die("no .data table %s of %d-byte entries" % (name, ent))
    lo, n = s["value"], s["size"] // ent
    di = B.idx[".data"]
    d = B.data[di]
    rel = B.rela[di]
    ents = [[r for r in rel if lo + k * ent <= r[0] < lo + (k + 1) * ent] for k in range(n)]
    drop = []
    for k, rs in enumerate(ents):
        names = {B.syms[r[1]]["name"] for r in rs}
        if any(r[1] in gone for r in rs):
            if not names & drop_names:
                die("%s[%d] reaches the ranges through %s" % (name, k, ",".join(sorted(names))))
            drop.append((k, sorted(names)))
    keep = [k for k in range(n) if k not in {k for k, _ in drop}]
    old = bytes(d[lo:lo + n * ent])
    for j, k in enumerate(keep):
        d[lo + j * ent:lo + (j + 1) * ent] = old[k * ent:(k + 1) * ent]
        for r in ents[k]:
            r[0] -= (k - j) * ent
    d[lo + len(keep) * ent:lo + n * ent] = bytes(ent * (n - len(keep)))
    dead = {id(r) for k, _ in drop for r in ents[k]}
    B.rela[di] = sorted((r for r in rel if id(r) not in dead), key=lambda r: r[0])
    return drop, lo, n


def corelist(path):
    names = []
    for line in open(path):
        w = line.split("#")[0].split()
        if w:
            names.append(w[0])
    return names


def check(e, core, private=None):
    """Gates B and C on an output, and nothing of ufs or s5 left by name."""
    g = e.glob()
    syms = {s["name"] for s in e.syms if s["name"]}
    left = [n for n in OWN if n in syms]
    if left:
        die("%s still names %s" % (e.path, " ".join(left)))
    if private is not None:
        left = sorted(n for n in private if n in syms)
        if left:
            die("gate B: the private COMMONs %s are still in the symbol table" % " ".join(left))
    if core is not None:
        miss = [n for n in core if n not in g or g[n]["shndx"] == SHN_UNDEF]
        if miss:
            die("gate C: core-tier names not defined in the cut: %s" % " ".join(miss))
    vs = g.get("vfssw")
    if vs:
        d = e.data[e.idx[".data"]]
        for off, typ, n, add in e.relocs(".data"):
            if vs["value"] <= off < vs["value"] + vs["size"] and n in INITS.values():
                die("vfssw still calls %s" % n)


def main():
    a = sys.argv[1:]
    core = None
    if "--core-list" in a:
        k = a.index("--core-list")
        core = corelist(a[k + 1])
        del a[k:k + 2]
    if a[:1] == ["--check"]:
        if len(a) != 2:
            die("usage: --check [--core-list LIST] OUT")
        e = Elf(a[1])
        e.path = a[1]
        check(e, core, {s["name"] for s in e.syms if s["shndx"] == SHN_COMMON} & {
            "ihead", "hinode", "inode", "ufs_inode", "updlock", "dquot", "dqhead"})
        g = e.glob()
        # after relink-040-dlm.sh the stock count is __amix_nfstype (nfstype is the core's live count)
        nn = "__amix_nfstype" if "__amix_nfstype" in g else "nfstype"
        nf = u32(e.data[e.idx[".data"]], g[nn]["value"]) if nn in g else None
        print("[ok] %s: no ufs or s5 by name, %s %s%s" % (a[1], nn, nf, ", %d core-tier names defined" % len(core)
                                                                  if core is not None else ""))
        return
    objs, stock = {}, None
    rest = []
    while a:
        x = a.pop(0)
        if x == "--stock" and a:
            stock = a.pop(0)
        elif x == "--obj" and a and "=" in a[0]:
            fs, p = a.pop(0).split("=", 1)
            if fs not in INITS:
                die("--obj %s: only ufs and s5" % fs)
            objs[fs] = p
        else:
            rest.append(x)
    if not stock or not objs or len(rest) != 2:
        die("usage: carve_fs040.py --stock UNIX --obj ufs=EXP --obj s5=EXP [--core-list LIST] BASE OUT")
    base, out = rest
    U, B = Elf(stock), Elf(base)
    B.path = base
    B0 = Elf(base)

    rng, gone, ocommons = [], set(), set()
    for fs in sorted(objs):
        r, mine, com = ranges_of(fs, U, B, Elf(objs[fs]))
        rng.append(r)
        gone |= mine
        ocommons |= com
        print("[*] %s: .text 0x%x-0x%x (%d), .data 0x%x-0x%x (%d), local .bss %s; %d symbols"
              % (fs, r[".text"][0], r[".text"][1], r[".text"][1] - r[".text"][0], r[".data"][0], r[".data"][1],
                 r[".data"][1] - r[".data"][0],
                 "0x%x-0x%x" % r[".bss"] if ".bss" in r else "none", len(mine)))

    # the COMMONs only the ranges use
    users = {}
    for sec in (".text", ".data"):
        for off, si, typ, add in B.rela[B.idx[sec]]:
            if B.syms[si]["shndx"] == SHN_COMMON:
                users.setdefault(si, set()).add(inside(rng, sec, off))
    private = {si for si, w in users.items() if w == {True}}
    pnames = {B.syms[si]["name"] for si in private}
    if core is not None:
        want = ocommons - set(core)
        if pnames != want:
            die("gate B: the COMMONs only the ranges use are not the objects' less the core tier (%s)"
                % " ".join(sorted(pnames ^ want)))
    gone |= private

    # gate A, before: what reaches in from outside the ranges
    into = []
    for sec in (".text", ".data"):
        for off, si, typ, add in B.rela[B.idx[sec]]:
            if not inside(rng, sec, off) and reaches(B, rng, gone, sec, off, si, add):
                into.append((sec, off, B.syms[si]["name"]))
    print("[*] relocations from outside into the ranges: %s"
          % ", ".join("%s+0x%x -> %s" % x for x in into))

    # step 2: the tables
    vd, vlo, vn = table(B, "vfssw", VFSSW_ROW, set(INITS[f] for f in objs), gone)
    nf = B.glob().get("nfstype")
    d = B.data[B.idx[".data"]]
    if not nf or B.secname(nf["shndx"]) != ".data" or u32(d, nf["value"]) != vn:
        die("nfstype is not vfssw's %d rows" % vn)
    if any(nf["value"] <= r[0] < nf["value"] + 4 for r in B.rela[B.idx[".data"]]):
        die("nfstype carries a relocation")
    struct.pack_into(">I", d, nf["value"], vn - len(vd))
    if sorted(n for _, ns in vd for n in ns if n in INITS.values()) != sorted(INITS[f] for f in objs):
        die("vfssw: the rows dropped are not one per object (%s)" % vd)
    it = B.glob().get("init_tbl")
    idrop, ilo, inn = table(B, "init_tbl", 4, {"inoinit"}, gone)
    if u32(d, ilo + (inn - 1) * 4):
        die("init_tbl does not end in a zero word")
    for k, ns in vd:
        print("    vfssw[%d] (%s) dropped" % (k, ",".join(ns)))
    for k, ns in idrop:
        print("    init_tbl[%d] (%s) dropped" % (k, ",".join(ns)))
    print("    nfstype %d -> %d" % (vn, vn - len(vd)))

    # step 3: relocations in the ranges dropped, bytes zeroed
    nrel = 0
    for sec in (".text", ".data"):
        i = B.idx[sec]
        keep = [r for r in B.rela[i] if not inside(rng, sec, r[0])]
        nrel += len(B.rela[i]) - len(keep)
        B.rela[i] = keep
        for r in rng:
            lo, hi = r[sec]
            B.data[i][lo:hi] = bytes(hi - lo)

    # gate A, after: nothing reaches in, nothing names a removed symbol
    for sec in (".text", ".data"):
        for off, si, typ, add in B.rela[B.idx[sec]]:
            if reaches(B, rng, gone, sec, off, si, add):
                die("gate A: %s+0x%x still reaches into a carved range (%s)" % (sec, off, B.syms[si]["name"]))

    # step 4: the symbols leave
    remap, syms = {}, []
    for i, s in enumerate(B.syms):
        if i not in gone:
            remap[i] = len(syms)
            syms.append(s)
    if any(not B.is_local(s) for s in syms[:sum(1 for s in syms if B.is_local(s))]):
        die("the symbol table's locals are not first")
    B.syms = syms
    for i in B.rela:
        B.rela[i] = [[off, remap[si], typ, add] for off, si, typ, add in B.rela[i]]
    B.write(out)

    # read back: gates A to D on the output
    E = Elf(out)
    E.path = out
    check(E, core, pnames)
    for sec in (".text", ".data"):
        i0, i1 = B0.idx[sec], E.idx[sec]
        o, n = B0.data[i0], E.data[i1]
        tabs = [(vlo, vlo + vn * VFSSW_ROW), (nf["value"], nf["value"] + 4), (ilo, ilo + inn * 4)] if sec == ".data" else []
        free = lambda x: inside(rng, sec, x) or any(lo <= x < hi for lo, hi in tabs)
        if len(o) != len(n) or any(o[x] != n[x] for x in range(len(o)) if not free(x)):
            die("gate D: %s outside the ranges and tables is not the input's" % sec)
        if any(n[lo:hi].count(0) != hi - lo for r in rng for lo, hi in [r[sec]]):
            die("%s ranges are not zero" % sec)
        ro = sorted((off, t, nm, ad) for off, t, nm, ad in B0.relocs(sec) if not free(off))
        rn = sorted((off, t, nm, ad) for off, t, nm, ad in E.relocs(sec) if not free(off))
        if ro != rn:
            die("gate D: %s's relocations outside the ranges and tables are not the input's" % sec)
        if any(inside(rng, sec, r[0]) for r in E.relocs(sec)):
            die("gate A: a relocation is left inside a %s range" % sec)
    zt = sum(r[".text"][1] - r[".text"][0] for r in rng)
    zd = sum(r[".data"][1] - r[".data"][0] for r in rng)
    zb = sum(r[".bss"][1] - r[".bss"][0] for r in rng if ".bss" in r)
    cb = sum(B0.syms[si]["size"] for si in private)
    print("[*] gate A: %d relocations into the ranges before (the table entries), none after; %d inside dropped"
          % (len(into), nrel))
    print("[*] gate B: %d private COMMONs gone (%d bytes): %s" % (len(pnames), cb, " ".join(sorted(pnames))))
    if core is not None:
        print("[*] gate C: the %d core-tier names are defined in the cut" % len(core))
    print("[*] gate D: .text/.data outside the ranges and tables = the input's, relocations too")
    print("[*] dead and zeroed: .text %d bytes, .data %d bytes (%d in all), local .bss %d bytes; "
          "%d symbols removed; the image keeps its size and every address"
          % (zt, zd, zt + zd, zb, len(gone)))


main()
