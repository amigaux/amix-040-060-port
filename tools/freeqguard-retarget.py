#!/usr/bin/env python3
"""freeqguard-retarget.py -- retarget every use of freeq to freeq_guarded (grimoire quirk 92).

  freeqguard-retarget.py UNIX           patch the linked ET_REL kernel in place (idempotent)
  freeqguard-retarget.py --check UNIX   verify, write nothing; exit 1 if the kernel is not retargeted

src/freeqguard.c defines freeq_guarded, which takes the pair off the STREAMS run and scan lists and calls the
stock freeq.  Every .rela entry naming freeq is found by symbol, never by a fixed address, and only its symbol
index changes: no byte of .text moves.  The one entry left naming freeq is freeq_guarded's own call.  The check
wants exactly that: freeq named only from freeq_guarded, and freeq_guarded named from qdetach and strclose (the
two stock callers that free a stream's queues).
"""
import struct, sys

SHT_SYMTAB, SHT_RELA = 2, 4
MUST = ('qdetach', 'strclose')


def load(path):
    b = bytearray(open(path, 'rb').read())
    if b[:4] != b'\x7fELF' or b[4] != 1 or b[5] != 2 or struct.unpack_from('>H', b, 16)[0] != 1:
        sys.exit('freeqguard-retarget: %s is not an ELF32 big-endian ET_REL' % path)
    shoff, = struct.unpack_from('>I', b, 32)
    shentsize, shnum = struct.unpack_from('>HH', b, 46)
    sh = [struct.unpack_from('>IIIIIIIIII', b, shoff + i * shentsize) for i in range(shnum)]
    symtab = [s for s in sh if s[1] == SHT_SYMTAB]
    if len(symtab) != 1:
        sys.exit('freeqguard-retarget: %d symbol tables' % len(symtab))
    st = symtab[0]
    stroff = sh[st[6]][4]
    syms = []
    for i in range(st[5] // 16):
        name, value, size, info, other, shndx = struct.unpack_from('>IIIBBH', b, st[4] + 16 * i)
        syms.append((bytes(b[stroff + name:b.index(0, stroff + name)]).decode(), value, shndx, info))
    return b, sh, syms


def index_of(syms, name):
    hits = [i for i, s in enumerate(syms) if s[0] == name and s[2] != 0]
    if len(hits) != 1:
        sys.exit('freeqguard-retarget: %d defined symbols named %s' % (len(hits), name))
    return hits[0]


def callers(b, sh, syms, target):
    """(rela entry file offset, containing function) for every .rela entry against `target`."""
    out = []
    ti = [i for i, s in enumerate(syms) if s[0] == target]
    for s in sh:
        if s[1] != SHT_RELA:
            continue
        sec = s[7]                                   # sh_info: the section the relocations apply to
        funcs = sorted((v, n) for n, v, x, info in syms if x == sec and n and (info & 15) in (0, 1, 2))
        for o in range(s[4], s[4] + s[5], 12):
            off, info, add = struct.unpack_from('>IIi', b, o)
            if info >> 8 in ti:
                fn = [n for v, n in funcs if v <= off]
                out.append((o, fn[-1] if fn else '?'))
    return out


def main():
    check = sys.argv[1:2] == ['--check']
    path = sys.argv[2] if check else (sys.argv[1] if len(sys.argv) == 2 else None)
    if not path:
        sys.exit(__doc__)
    b, sh, syms = load(path)
    guarded = index_of(syms, 'freeq_guarded')
    index_of(syms, 'freeq')
    plain = [fn for o, fn in callers(b, sh, syms, 'freeq')]
    done = sorted(fn for o, fn in callers(b, sh, syms, 'freeq_guarded'))
    if check:
        ok = plain == ['freeq_guarded'] and all(f in done for f in MUST)
        print('freeqguard-retarget: freeq_guarded named from %s; freeq from %s -- %s'
              % (done or 'nowhere', sorted(plain) or 'nowhere', 'OK' if ok else 'NOT RETARGETED'))
        sys.exit(0 if ok else 1)
    todo = [(o, fn) for o, fn in callers(b, sh, syms, 'freeq') if fn != 'freeq_guarded']
    if not todo:
        print('freeqguard-retarget: already retargeted' if done else 'freeqguard-retarget: nothing names freeq')
        return
    for o, fn in todo:
        off, info, add = struct.unpack_from('>IIi', b, o)
        struct.pack_into('>IIi', b, o, off, (guarded << 8) | (info & 0xff), add)
    open(path, 'wb').write(b)
    print('freeqguard-retarget: %d relocations freeq -> freeq_guarded, in %s'
          % (len(todo), ' '.join(sorted(set(fn for o, fn in todo)))))


if __name__ == '__main__':
    main()
