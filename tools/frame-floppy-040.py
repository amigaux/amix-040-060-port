#!/usr/bin/env python3
"""frame-floppy-040.py -- frame a kernel of this line into a bootable 880 KB DF0 floppy (2026-10-02,
P-15 P3 / KT-16).

WHY THE STOCK FLOPPY CANNOT BOOT A 68040/68060 KERNEL.  The AMIX 2.1 boot floppy is the same chain
as a boot slice, laid at offset 0 of the disk:

    0x0000  boot1      the AmigaDOS bootblock (1 KB, with its checksum)
    0x0400  IBLK       { "IBLK", size 0x2000, fullsize 0, chksum, bind }
    0x0600  boot2      8192 bytes: the name-based loader (sha256 5ab360b1...)
    0x2600  IBLK       { "IBLK", size, fullsize (decompressed), chksum, bind }
    0x2800  the kernel, an LZW (`compress -b16`) stream of a brel image (ELF e_type 0xff00)

and that boot2 cannot start this line's kernels for the two reasons amix-kerntools'
docs/boot2-040.md gives for the disk loader: copyit's `pmove`s are F-line on a 68040/68060, and
rel.c knows only R_68K_32.  The answer for each is already built:

  * boot2-040 (amix-kerntools, contract identity good_040, sha256 fd7dacf6...) is the flags-based
    loader with the CPU dispatch and the PC-relative cases.  It is the same program for both
    media: boot2.c reads through the device boot1 opened, decompresses when ib_fullsize > 0, and
    rel.c accepts ET_LOPROC (brel) as well as ET_REL.
  * amix-kerntools' tools/elf2brel.py applies the 330 PC-relative relocations at conversion time
    (all intra-.text), so the brel carries R_68K_32 entries only.

So this tool is framing: the donor floppy's boot1 unchanged, its boot2 replaced by boot2-040 and
that IBLK's checksum recomputed, and a new kernel payload with its IBLK.  The donor and boot2 are
proprietary Commodore bytes: they are read from the reader's own files and never stored here.

Every input is checked before anything is written: the donor's layout, both of its IBLK checksums
and its bootblock checksum; boot2-040's size and sha256; the brel's e_type; the compressed stream
decompresses back to the brel byte for byte; and the payload fits.  The output's own layout is then
re-read and re-checked.

usage: frame-floppy-040.py --donor ADF --boot2 FILE --boot2-sha256 HEX --brel FILE --out ADF
"""
import argparse
import hashlib
import struct
import subprocess
import sys

ADF = 901120
BOOT1, IB2, B2, IBK, KER = 0x0, 0x400, 0x600, 0x2600, 0x2800
B2SIZE = 0x2000


def fold(data):
    """SVR4 sum-compatible checksum (amiga/boot chksum.c): byte sum folded to 16 bits."""
    s = sum(data)
    t = (s >> 16) + (s & 0xFFFF)
    return (t >> 16) + (t & 0xFFFF)


def bootblock_ok(b):
    s = 0
    for i in range(256):
        s += struct.unpack(">I", b[i * 4:i * 4 + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    return s == 0xFFFFFFFF


def iblk(b, off):
    if b[off:off + 5] != b"IBLK\0":
        raise SystemExit("ABORT: no IBLK at 0x%x" % off)
    return struct.unpack(">IIII", b[off + 8:off + 24])


def check_layout(b, what):
    if len(b) != ADF:
        raise SystemExit("ABORT: %s is %d bytes, not an 880 KB ADF" % (what, len(b)))
    if b[0:3] != b"DOS" or not bootblock_ok(b):
        raise SystemExit("ABORT: %s has no valid AmigaDOS bootblock" % what)
    size, full, ck, _ = iblk(b, IB2)
    if size != B2SIZE or full != 0 or ck != fold(b[B2:B2 + B2SIZE]):
        raise SystemExit("ABORT: %s: boot2's IBLK is %x/%x/%x, or its checksum is wrong" % (what, size, full, ck))
    size, full, ck, _ = iblk(b, IBK)
    if KER + size > ADF or ck != fold(b[KER:KER + size]):
        raise SystemExit("ABORT: %s: the kernel IBLK does not describe its payload" % what)
    return size, full


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--donor", required=True)
    ap.add_argument("--boot2", required=True)
    ap.add_argument("--boot2-sha256", required=True)
    ap.add_argument("--brel", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    donor = open(a.donor, "rb").read()
    dsize, dfull = check_layout(donor, "the donor")
    print("  donor: boot2 %s..., kernel %d -> %d bytes, checksums and bootblock valid"
          % (hashlib.sha256(donor[B2:B2 + B2SIZE]).hexdigest()[:8], dsize, dfull))

    boot2 = open(a.boot2, "rb").read()
    sha = hashlib.sha256(boot2).hexdigest()
    if len(boot2) != B2SIZE or sha != a.boot2_sha256:
        raise SystemExit("ABORT: boot2 is %d bytes, sha256 %s -- not %s" % (len(boot2), sha, a.boot2_sha256))
    print("  boot2: %s (%d bytes), the identity asked for" % (sha[:16], len(boot2)))

    brel = open(a.brel, "rb").read()
    if brel[:4] != b"\x7fELF" or struct.unpack(">H", brel[16:18])[0] != 0xFF00:
        raise SystemExit("ABORT: %s is not a brel (ELF e_type 0xff00)" % a.brel)
    z = subprocess.run(["compress", "-b16", "-c"], input=brel, capture_output=True).stdout
    back = subprocess.run(["compress", "-d", "-c"], input=z, capture_output=True).stdout
    if not z or back != brel:
        raise SystemExit("ABORT: compress -b16 does not round-trip the brel")
    room = ADF - KER
    if len(z) > room:
        raise SystemExit("ABORT: the compressed kernel is %d bytes, %d over the %d-byte floppy budget"
                         % (len(z), len(z) - room, room))
    print("  kernel: brel %d bytes -> LZW %d bytes, round-trips; %d of %d bytes free"
          % (len(brel), len(z), room - len(z), room))

    out = bytearray(ADF)
    out[BOOT1:IB2] = donor[BOOT1:IB2]                          # boot1, unchanged
    out[IB2:B2] = donor[IB2:B2]
    struct.pack_into(">I", out, IB2 + 16, fold(boot2))         # boot2's IBLK: only the checksum moves
    out[B2:B2 + B2SIZE] = boot2
    out[IBK:KER] = donor[IBK:KER]
    struct.pack_into(">III", out, IBK + 8, len(z), len(brel), fold(z))
    out[KER:KER + len(z)] = z

    ksize, kfull = check_layout(bytes(out), "the output")
    if (ksize, kfull) != (len(z), len(brel)) or bytes(out[B2:B2 + B2SIZE]) != boot2:
        raise SystemExit("ABORT: the output does not read back as written")
    open(a.out, "wb").write(out)
    print("  wrote %s: boot1 (donor) | boot2 %s | kernel %d -> %d; layout re-read and valid"
          % (a.out, sha[:8], len(z), len(brel)))


main()
