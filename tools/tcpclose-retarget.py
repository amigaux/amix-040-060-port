#!/usr/bin/env python3
"""tcpclose-retarget.py -- TCP's stream close goes through tcpclose_lg (src/tcpclose_lg.c; ISSUE-118).

  tcpclose-retarget.py UNIX            patch the linked ET_REL kernel in place (idempotent)
  tcpclose-retarget.py --check UNIX    verify, write nothing; exit 1 unless retargeted and tcpclose_lg calls tcpclose
  tcpclose-retarget.py --selftest      a synthetic object: retargeted, idempotent, --check both ways, every refusal

STREAMS closes a stream through its upper read queue's qinit only, so the one .rela.data entry changed is
tcpurinit's qi_qclose (tcpurinit + 12), and only its symbol index: no byte of .data moves.  The three other qinits'
tcpclose stay.  Asserted before anything is written: tcpurinit is one defined symbol whose relocations are exactly
+4 tcp_deqdata (qi_srvp), +8 tcpopen (qi_qopen), +12 tcpclose or tcpclose_lg (qi_qclose), +20 tcpm_info (qi_minfo),
all R_68K_32 with addend 0; tcpinfo + 0 names tcpurinit (the streamtab's st_rdinit); tcpclose_lg and tcl_magic
are defined once.
"""
import struct, sys

SHT_SYMTAB, SHT_RELA = 2, 4
CTX = {4: 'tcp_deqdata', 8: 'tcpopen', 20: 'tcpm_info'}
SLOT = 12


def fail(msg):
    sys.exit('tcpclose-retarget: ' + msg)


def load(path):
    b = bytearray(open(path, 'rb').read())
    if b[:4] != b'\x7fELF' or b[4] != 1 or b[5] != 2 or struct.unpack_from('>H', b, 16)[0] != 1:
        fail('%s is not an ELF32 big-endian ET_REL' % path)
    shoff, = struct.unpack_from('>I', b, 32)
    shentsize, shnum = struct.unpack_from('>HH', b, 46)
    sh = [struct.unpack_from('>IIIIIIIIII', b, shoff + i * shentsize) for i in range(shnum)]
    symtab = [s for s in sh if s[1] == SHT_SYMTAB]
    if len(symtab) != 1:
        fail('%d symbol tables' % len(symtab))
    st = symtab[0]
    stroff = sh[st[6]][4]
    syms = []
    for i in range(st[5] // 16):
        name, value, size, info, other, shndx = struct.unpack_from('>IIIBBH', b, st[4] + 16 * i)
        syms.append((bytes(b[stroff + name:b.index(0, stroff + name)]).decode('latin-1'), value, shndx, info))
    return b, sh, syms


def defined(syms, name):
    hits = [i for i, s in enumerate(syms) if s[0] == name and s[2] not in (0, 0xfff1, 0xfff2)]
    if len(hits) != 1:
        fail('%d definitions of %s' % (len(hits), name))
    return hits[0]


def relas(b, sh, syms):
    """{(section index, offset): (file offset of the entry, type, symbol name, addend)} over every SHT_RELA."""
    out = {}
    for s in sh:
        if s[1] != SHT_RELA:
            continue
        for o in range(s[4], s[4] + s[5], 12):
            off, info, add = struct.unpack_from('>IIi', b, o)
            out[(s[7], off)] = (o, info & 0xff, syms[info >> 8][0], add)
    return out


def site(b, sh, syms):
    """(file offset of the qi_qclose entry's r_info, tcpclose_lg's symbol index, its current name)"""
    u = defined(syms, 'tcpurinit')
    lg = defined(syms, 'tcpclose_lg')
    defined(syms, 'tcl_magic')
    _, base, sec, _ = syms[u]
    r = relas(b, sh, syms)
    for off, want in CTX.items():
        got = r.get((sec, base + off))
        if not got or got[1:] != (1, want, 0):
            fail('tcpurinit+%d is %s, expected R_68K_32 %s+0' % (off, got and got[1:], want))
    got = r.get((sec, base + SLOT))
    if not got or got[1] != 1 or got[3] != 0 or got[2] not in ('tcpclose', 'tcpclose_lg'):
        fail('tcpurinit+%d (qi_qclose) is %s, expected R_68K_32 tcpclose+0' % (SLOT, got and got[1:]))
    t = defined(syms, 'tcpinfo')
    _, tv, ts, _ = syms[t]
    got = r.get((ts, tv))
    if not got or got[1:] != (1, 'tcpurinit', 0):
        fail('tcpinfo+0 (st_rdinit) is %s, expected R_68K_32 tcpurinit+0' % (got and got[1:],))
    q = r[(sec, base + SLOT)]
    return q[0] + 4, lg, q[2], r


def main(args=None):
    args = sys.argv[1:] if args is None else args
    if args == ['--selftest']:
        return selftest()
    check = args[:1] == ['--check']
    if check:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    b, sh, syms = load(args[0])
    at, lg, cur, r = site(b, sh, syms)
    if check:
        if cur != 'tcpclose_lg':
            fail('%s: TCP\'s qi_qclose still names tcpclose' % args[0])
        _, lv, ls, _ = syms[lg]
        size = struct.unpack_from('>I', b, [s for s in sh if s[1] == SHT_SYMTAB][0][4] + 16 * lg + 8)[0]
        if not any(k[0] == ls and lv <= k[1] < lv + size and v[2] == 'tcpclose' for k, v in r.items()):
            fail('%s: tcpclose_lg does not call tcpclose' % args[0])
        print('tcpclose-retarget: %s: tcpurinit qi_qclose -> tcpclose_lg' % args[0])
        return
    if cur == 'tcpclose_lg':
        print('tcpclose-retarget: %s: already retargeted' % args[0])
        return
    info, = struct.unpack_from('>I', b, at)
    struct.pack_into('>I', b, at, (lg << 8) | (info & 0xff))
    open(args[0], 'wb').write(b)
    print('tcpclose-retarget: %s: tcpurinit qi_qclose now names tcpclose_lg' % args[0])


def synth(path, slot='tcpclose', ctx=None, rd='tcpurinit', defs=('tcpclose_lg', 'tcl_magic'), lgcall=True):
    """a minimal ET_REL: .text (tcpclose, tcpclose_lg), .data (tcpurinit 24 bytes, tcpinfo 4), their relocations"""
    ctx = dict(CTX) if ctx is None else ctx
    names = ['tcpurinit', 'tcpinfo', 'tcpclose', 'tcpclose_lg', 'tcl_magic', 'tcp_deqdata', 'tcpopen', 'tcpm_info']
    strtab = b'\0' + b''.join(n.encode() + b'\0' for n in names)
    off = {}
    p = 1
    for n in names:
        off[n] = p
        p += len(n) + 1
    text = bytes.fromhex('4e754e714eb9000000004e75')       # tcpclose: rts; nop; tcpclose_lg: jsr tcpclose; rts
    data = bytes(28) + bytes(4)                               # tcpurinit (24 + pad), tcpinfo
    sym = bytes(16)
    sym += struct.pack('>IIIBBH', off['tcpurinit'], 0, 24, 0x01, 0, 2)
    sym += struct.pack('>IIIBBH', off['tcpinfo'], 28, 4, 0x11, 0, 2)
    sym += struct.pack('>IIIBBH', off['tcpclose'], 0, 2, 0x12, 0, 1)
    sym += struct.pack('>IIIBBH', off['tcpclose_lg'], 4, 8, 0x12, 0, 1 if 'tcpclose_lg' in defs else 0)
    sym += struct.pack('>IIIBBH', off['tcl_magic'], 0, 4, 0x11, 0, 2 if 'tcl_magic' in defs else 0)
    for n in ('tcp_deqdata', 'tcpopen', 'tcpm_info'):
        sym += struct.pack('>IIIBBH', off[n], 0, 0, 0x10, 0, 0)
    idx = {n: i + 1 for i, n in enumerate(names)}
    rd_data = b''.join(struct.pack('>IIi', o, (idx[n] << 8) | 1, 0) for o, n in sorted(ctx.items()))
    rd_data += struct.pack('>IIi', SLOT, (idx[slot] << 8) | 1, 0)
    rd_data += struct.pack('>IIi', 28, (idx[rd] << 8) | 1, 0)
    rd_text = struct.pack('>IIi', 6, (idx['tcpclose'] << 8) | 1, 0) if lgcall else b''
    shstr = b'\0.text\0.data\0.rela.text\0.rela.data\0.symtab\0.strtab\0.shstrtab\0'
    body = [text, data, rd_text, rd_data, sym, strtab, shstr]
    pos, offs = 52, []
    for x in body:
        offs.append(pos)
        pos += (len(x) + 3) & ~3
    out = bytearray(struct.pack('>4sBBBB8xHHIIIIIHHHHHH', b'\x7fELF', 1, 2, 1, 0, 1, 4, 1, 0, 0, pos, 0, 52,
                                0, 0, 40, 8, 7))
    for x in body:
        out += x + bytes(((len(x) + 3) & ~3) - len(x))
    sh = [(0,) * 10, (1, 1, 6, 0, offs[0], len(text), 0, 0, 2, 0), (7, 1, 3, 0, offs[1], len(data), 0, 0, 4, 0),
          (13, 4, 0, 0, offs[2], len(rd_text), 5, 1, 4, 12), (24, 4, 0, 0, offs[3], len(rd_data), 5, 2, 4, 12),
          (35, 2, 0, 0, offs[4], len(sym), 6, 1, 4, 16), (43, 3, 0, 0, offs[5], len(strtab), 0, 0, 1, 0),
          (51, 3, 0, 0, offs[6], len(shstr), 0, 0, 1, 0)]
    for s in sh:
        out += struct.pack('>IIIIIIIIII', *s)
    open(path, 'wb').write(out)


def selftest():
    import contextlib, io, os, tempfile

    def run(args):
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                main(args)
            return 0
        except SystemExit as e:
            return 1 if e.code else 0
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'unix')
        synth(p)
        before = open(p, 'rb').read()
        assert run(['--check', p]) == 1, 'an unretargeted object passed --check'
        assert run([p]) == 0, 'the pinned object was not retargeted'
        after = open(p, 'rb').read()
        assert sum(1 for i in range(len(before)) if before[i] != after[i]) in (1, 2, 3), 'more than one r_info changed'
        assert run(['--check', p]) == 0, 'the retargeted object failed --check'
        assert run([p]) == 0 and open(p, 'rb').read() == after, 'a second run changed the object'
        bad = (('qi_srvp changed', dict(ctx={4: 'tcpopen', 8: 'tcpopen', 20: 'tcpm_info'})),
               ('qi_qopen missing', dict(ctx={4: 'tcp_deqdata', 20: 'tcpm_info'})),
               ('qi_minfo changed', dict(ctx={4: 'tcp_deqdata', 8: 'tcpopen', 20: 'tcpopen'})),
               ('qi_qclose names another routine', dict(slot='tcpopen')),
               ('st_rdinit names another qinit', dict(rd='tcpinfo')),
               ('no tcpclose_lg defined', dict(defs=('tcl_magic',))),
               ('no tcl_magic', dict(defs=('tcpclose_lg',))))
        for what, kw in bad:
            synth(p, **kw)
            b0 = open(p, 'rb').read()
            assert run([p]) != 0 and open(p, 'rb').read() == b0, 'an object with %s was not refused' % what
        synth(p, lgcall=False)
        run([p])
        assert run(['--check', p]) != 0, 'a tcpclose_lg that does not call tcpclose passed --check'
    print('tcpclose-retarget selftest: the qclose slot retargeted (one r_info), idempotent, --check both ways, '
          '%d bad contexts or objects refused, a tcpclose_lg without its tcpclose call refused by --check' % len(bad))


if __name__ == '__main__':
    main()
