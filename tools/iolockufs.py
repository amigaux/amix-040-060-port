#!/usr/bin/env python3
"""iolockufs.py -- the k46 ufs module's rwip calls as_iolock_ufs (src/as_iolock_ufs.c) instead of as_iolock.

  iolockufs.py OBJ            retarget, in place, in the ufs object linked with as_iolock_ufs.o (ELF32 big-endian
                              ET_REL); refuses unless rwip and its call are exactly the pinned ones
  iolockufs.py --check OBJ    verify, write nothing; exit 1 unless retargeted
  iolockufs.py --digest OBJ   print rwip's digest (what RWIP_DIGESTS pins)
  iolockufs.py --selftest     a synthetic object: retargeted, idempotent, --check both ways, every refusal

src/as_iolock_ufs.c says why.  tools/ufs-holefix.sh runs this after the link.  Only the r_info of rwip's one
as_iolock relocation changes (its symbol index, so 1 to 3 bytes): no byte of .text moves, and every other caller
(the wrapper's own call, nfs's rwvp in its module) keeps the stock as_iolock.  rwip must be the pinned code:
  - its digest (its bytes with every relocated field zeroed, the rwip fix's 4 bytes at rwip + 0x3d6 zeroed, and
    its relocations by offset, type, symbol and addend, as_iolock_ufs counted as as_iolock) is in RWIP_DIGESTS;
  - the call, byte for byte: as_iolock(uio, &iolpl, n, vp, old size, &pagecreate) at rwip + 0x1d2, pagecreate at
    fp@(-28), the n it returns stored at fp@(-116), the stack adjusted by 24;
  - exactly one relocation of as_iolock (or as_iolock_ufs) in rwip, at rwip + 0x1e8, R_68K_32 with addend 0;
  - as_iolock_ufs and ufs_pc_magic each defined once in the object.
"""
import hashlib, os, struct, sys

# pea fp@(-28) (&pagecreate); movel d4 (old size); movel d7 (vp); movel fp@(-116) (n); pea fp@(-24) (&iolpl);
# movel fp@(12) (uio); jsr <as_iolock>
BEFORE = bytes.fromhex('486effe42f042f072f2eff8c486effe82f2e000c4eb9')
AFTER = bytes.fromhex('2d40ff8cdefc0018')          # movel d0,fp@(-116); addaw #24,sp
CALL_RELOC = 0x1e8                                  # the jsr's address field, from rwip's start
RWIP_FIX = 0x3d6                                    # tools/fsobj-patch.py's rwip site: 2f2eff94 stock, 48703800 fixed
RWIP_FIX_BYTES = (bytes.fromhex('2f2eff94'), bytes.fromhex('48703800'))
# rwip in the stock ufs object (/usr/sys/fs/ufs/exp a439e68f) after tools/fsobj-patch.py, the same with
# UFS_RWIP_FIX=0, and after tools/ufs-tailzero.sh (which does not touch rwip)
RWIP_DIGESTS = {'c2caf0e9339eaaa9ed8e58420c1e9e9a8a9c180266d6d4480cad7afe4f1c14da'}
SYNTH_DIGEST = '224d84a78a12a5eb9e5f65e0c291f30126671c4f0f73efeb11cff0fe764ed407'   # synth()'s rwip
SPECIAL = (0, 0xfff1, 0xfff2)


def fail(msg):
    sys.exit('iolockufs: ' + msg)


def load(path):
    b = bytearray(open(path, 'rb').read())
    if b[:4] != b'\x7fELF' or b[4] != 1 or b[5] != 2 or struct.unpack_from('>H', b, 16)[0] != 1:
        fail('%s: not an ELF32 big-endian relocatable object' % path)
    shoff, = struct.unpack_from('>I', b, 32)
    shentsize, shnum = struct.unpack_from('>HH', b, 46)
    sh = [struct.unpack_from('>IIIIIIIIII', b, shoff + i * shentsize) for i in range(shnum)]
    syms = []
    for s in sh:
        if s[1] != 2:
            continue
        stroff = sh[s[6]][4]
        for o in range(s[4], s[4] + s[5], 16):
            nm, val, _, info, _, shndx = struct.unpack_from('>IIIBBH', b, o)
            syms.append((b[stroff + nm:b.index(0, stroff + nm)].decode('latin-1'), val, shndx, info))
    return b, sh, syms


def site(b, sh, syms, known):
    """(file offset of r_info, as_iolock_ufs's index, retargeted already, rwip's digest)"""
    r = [s for s in syms if s[0] == 'rwip' and s[2] not in SPECIAL]
    if len(r) != 1:
        fail('%d definitions of rwip' % len(r))
    _, start, sec, _ = r[0]
    later = sorted(v for n, v, x, info in syms if x == sec and v > start and (info & 15) == 2)
    end = later[0] if later else sh[sec][5]
    text = sh[sec][4]
    for name in ('as_iolock_ufs', 'ufs_pc_magic'):
        n = sum(1 for s in syms if s[0] == name and s[2] not in SPECIAL)
        if n != 1:
            fail('%s is defined %d times in the object (want 1: link src/as_iolock_ufs.c in first)' % (name, n))
    ufs = [i for i, s in enumerate(syms) if s[0] == 'as_iolock_ufs' and s[2] not in SPECIAL][0]
    rels, calls = [], []
    for s in sh:
        if s[1] != 4 or s[7] != sec:
            continue
        for o in range(s[4], s[4] + s[5], 12):
            off, info, add = struct.unpack_from('>IIi', b, o)
            if not start <= off < end:
                continue
            n, v, x, i = syms[info >> 8]
            if n in ('as_iolock', 'as_iolock_ufs'):
                calls.append((o, off, info, add, n))
                n = 'as_iolock'
            rels.append((off - start, info & 0xff, n if (i & 15) != 3 else '', add))
    if len(calls) != 1:
        fail('rwip names as_iolock %d times (want 1)' % len(calls))
    o, off, info, add, name = calls[0]
    if off - start != CALL_RELOC:
        fail('rwip\'s as_iolock relocation is at rwip+0x%x, not rwip+0x%x' % (off - start, CALL_RELOC))
    if info & 0xff != 1 or add:
        fail('rwip\'s as_iolock relocation is type %d with addend %d, not R_68K_32 with 0' % (info & 0xff, add))
    code = bytearray(b[text + start:text + end])
    k = off - start
    if code[k - len(BEFORE):k] != BEFORE or code[k + 4:k + 4 + len(AFTER)] != AFTER:
        fail('the call of as_iolock in rwip differs from the pinned one')
    if len(code) < RWIP_FIX + 4 or bytes(code[RWIP_FIX:RWIP_FIX + 4]) not in RWIP_FIX_BYTES:
        fail('rwip+0x%x is not the segmap_pagecreate push (stock or fixed)' % RWIP_FIX)
    for ro, t, n, a in rels:
        code[ro:ro + 4] = bytes(4)
    code[RWIP_FIX:RWIP_FIX + 4] = bytes(4)
    h = hashlib.sha256(bytes(code))
    h.update(repr(sorted(rels)).encode())
    d = h.hexdigest()
    if known is not None and d not in known:
        fail('rwip is not the pinned code (digest %s)' % d)
    return o + 4, ufs, name == 'as_iolock_ufs', d


def main(args=None, known=RWIP_DIGESTS):
    """known: the rwip digests accepted; None skips the digest (the selftest proves each other check alone)"""
    args = sys.argv[1:] if args is None else args
    if args == ['--selftest']:
        return selftest()
    mode = args[0] if args[:1] in (['--check'], ['--digest']) else ''
    if mode:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    b, sh, syms = load(args[0])
    at, ufs, done, d = site(b, sh, syms, None if mode == '--digest' else known)
    if mode == '--digest':
        print(d)
        return
    if mode == '--check':
        if not done:
            fail('%s: rwip still calls the stock as_iolock' % args[0])
        print('iolockufs: %s: rwip calls as_iolock_ufs' % args[0])
        return
    if done:
        print('iolockufs: %s: already retargeted' % args[0])
        return
    info, = struct.unpack_from('>I', b, at)
    struct.pack_into('>I', b, at, (ufs << 8) | (info & 0xff))
    open(args[0], 'wb').write(b)
    print('iolockufs: %s: rwip\'s as_iolock relocation now names as_iolock_ufs' % args[0])


def synth(path, mutate=None, call=('as_iolock', 1, 0), defs=('as_iolock_ufs', 'ufs_pc_magic'), fix=RWIP_FIX_BYTES[1],
          at=CALL_RELOC, twice=False):
    """a minimal ET_REL: rwip (the pinned call at rwip + 0x1d2, the rwip fix's 4 bytes at + 0x3d6), as_iolock_ufs;
    at moves the whole call, twice adds a second as_iolock relocation in rwip"""
    t = bytearray(bytes.fromhex('4e560000') + bytes(at - len(BEFORE) - 4) + BEFORE + bytes(4) + AFTER)
    t += bytes(RWIP_FIX - len(t)) + fix + bytes.fromhex('4e5e4e75')
    if mutate:
        mutate(t)
    g = bytes.fromhex('4e5e4e75' + '55504321')      # as_iolock_ufs's body, ufs_pc_magic
    names = ['rwip', 'as_iolock', 'as_iolock_ufs', 'ufs_pc_magic']
    strtab = b'\0' + b''.join(n.encode() + b'\0' for n in names)
    off = [1]
    for n in names[:-1]:
        off.append(off[-1] + len(n) + 1)
    sym = bytes(16) + struct.pack('>IIIBBH', off[0], 0, len(t), 0x12, 0, 1)
    sym += struct.pack('>IIIBBH', off[1], 0, 0, 0x10, 0, 0)
    sym += struct.pack('>IIIBBH', off[2], len(t), 4, 0x12, 0, 1 if 'as_iolock_ufs' in defs else 0)
    sym += struct.pack('>IIIBBH', off[3], len(t) + 4, 4, 0x11, 0, 1 if 'ufs_pc_magic' in defs else 0)
    cs = {'as_iolock': 2, 'as_iolock_ufs': 3}[call[0]]
    rela = struct.pack('>IIi', at + (call[3] if len(call) > 3 else 0), (cs << 8) | call[1], call[2])
    if twice:
        rela += struct.pack('>IIi', 8, (2 << 8) | 1, 0)
    shstr = b'\0.text\0.rela.text\0.symtab\0.strtab\0.shstrtab\0'
    body = [bytes(t) + g, rela, sym, strtab, shstr]
    pos, offs = 52, []
    for x in body:
        offs.append(pos)
        pos += (len(x) + 3) & ~3
    data = bytearray(struct.pack('>4sBBBB8xHHIIIIIHHHHHH', b'\x7fELF', 1, 2, 1, 0, 1, 4, 1, 0, 0, pos, 0, 52,
                                 0, 0, 40, 6, 5))
    for x in body:
        data += x + bytes(((len(x) + 3) & ~3) - len(x))
    sh = [(0, 0, 0, 0, 0, 0, 0, 0, 0, 0), (1, 1, 6, 0, offs[0], len(body[0]), 0, 0, 2, 0),
          (7, 4, 0, 0, offs[1], len(rela), 3, 1, 4, 12), (18, 2, 0, 0, offs[2], len(sym), 4, 1, 4, 16),
          (26, 3, 0, 0, offs[3], len(strtab), 0, 0, 1, 0), (34, 3, 0, 0, offs[4], len(shstr), 0, 0, 1, 0)]
    for s in sh:
        data += struct.pack('>IIIIIIIIII', *s)
    open(path, 'wb').write(data)


def selftest():
    import contextlib, io, tempfile
    known = {SYNTH_DIGEST}

    def run(args, k=known):
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                main(args, k)
            return 0
        except SystemExit as e:
            return 1 if e.code else 0
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'ufs.exp')
        synth(p)
        stock = open(p, 'rb').read()
        assert run(['--check', p]) == 1, 'the unretargeted object passed --check'
        assert run([p], {'0' * 64}) == 1 and open(p, 'rb').read() == stock, 'an unpinned rwip was retargeted'
        assert run([p]) == 0, 'the pinned object was not retargeted'
        new = open(p, 'rb').read()
        diff = [i for i in range(len(stock)) if stock[i] != new[i]]
        b, sh, syms = load(p)
        info, = struct.unpack_from('>I', b, sh[2][4] + 4)
        assert syms[info >> 8][0] == 'as_iolock_ufs' and len(diff) == 1, 'the relocation does not name as_iolock_ufs alone'
        assert run(['--check', p]) == 0, 'the retargeted object failed --check'
        assert run([p]) == 0 and open(p, 'rb').read() == new, 'a second run changed the object'
        synth(p, fix=RWIP_FIX_BYTES[0])
        assert run([p]) == 0, 'the object without the rwip fix (UFS_RWIP_FIX=0) was refused'
        cases = (('the pagecreate argument', CALL_RELOC - len(BEFORE) + 2, 'ffe0'),
                 ('the uio argument', CALL_RELOC - 2 - 2, '0010'),
                 ('the vp argument', CALL_RELOC - len(BEFORE) + 6, '2f06'),
                 ('the store of n', CALL_RELOC + 4, '2d41ff8c'),
                 ('the stack adjust', CALL_RELOC + 8, 'defc0014'),
                 ('the rwip fix site', RWIP_FIX, '4e714e71'))
        for what, at, hexb in cases:
            v = bytes.fromhex(hexb)
            synth(p, lambda t: t.__setitem__(slice(at, at + len(v)), v))
            before = open(p, 'rb').read()
            assert run([p], None) != 0 and open(p, 'rb').read() == before, 'a changed %s was not refused' % what
        rcases = (('an addend on the call', dict(call=('as_iolock', 1, 4))),
                  ('a PC-relative call', dict(call=('as_iolock', 5, 0))),
                  ('the relocation moved', dict(call=('as_iolock', 1, 0, 2))),
                  ('no as_iolock_ufs in the object', dict(defs=('ufs_pc_magic',))),
                  ('no ufs_pc_magic', dict(defs=('as_iolock_ufs',))),
                  ('the whole call moved by 2', dict(at=CALL_RELOC + 2)),
                  ('a second as_iolock relocation in rwip', dict(twice=True)))
        for what, kw in rcases:
            synth(p, **kw)
            before = open(p, 'rb').read()
            assert run([p], None) != 0 and open(p, 'rb').read() == before, 'an object with %s was not refused' % what
        synth(p, lambda t: t.__setitem__(slice(2, 4), bytes.fromhex('fff0')))
        before = open(p, 'rb').read()
        assert run(['--digest', p]) == 0, 'the frame change alone tripped a context check'
        assert run([p]) != 0 and open(p, 'rb').read() == before, 'a change only the digest sees was not refused'
    print('iolockufs selftest: the pinned call retargeted (one relocation), idempotent, --check both ways, with and '
          'without the rwip fix, an unpinned rwip, %d changed contexts, %d bad relocations or objects and a change only '
          'the digest sees refused' % (len(cases), len(rcases)))


if __name__ == '__main__':
    main()
