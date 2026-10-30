#!/bin/sh
# ufs-tailzero.sh -- the ufs module's object with ufs_itrunc's pvn_vptrunc call wrapped (grimoire quirk 91;
# 2026-10-30).  ON by default; UFS_TAILZERO=0 copies the object through unchanged.
#
# A shrink to a length M that is not block-aligned, past the 12 direct blocks, leaves
# [roundup(M, PAGESIZE), end of M's block) -- all of [M, end) on a cold cache -- holding the file's OLD bytes
# on disk, and a later regrow reads them back.  src/ufs_vptrunz.c zeroes that tail through segkmap and writes
# it synchronously before calling the stock pvn_vptrunc; see its comment.  The routine and this step are
# the 030 line's (amix kernel/k30 1be27f8, build-cross-kernel.sh 7b-qz and qz_check), ported.
#
# Where it runs: on a k46 module kernel ufs is a core-tier module, and its object is
# tools/fsobj-patch.py's output (docs/contracts/KINFO.md).  This step goes between that and amix-dlm's
# carve.py wrap, whose module build takes the result as its object:
#
#     fsobj-patch.py ... usr/sys/fs/ufs/exp -o ufs-exp.k46
#     sh tools/ufs-tailzero.sh ufs-exp.k46 ufs-exp-qz.k46
#
# The base kernel is not touched: ufs_itrunc is the only caller, and it lives in the module.
#
#   1. src/ufs_vptrunz.c, cross-compiled -m68040: its imports exactly kzero pvn_vptrunc segkmap
#      segmap_getmap segmap_release (names the ufs object imports already), its exports the routine and
#      the qz_* counters, its COMMONs only ufs_inode.h's, no multiply rewritten (AMIX_MUL64=keep gives the
#      same object), scan060 CLEAN;
#   2. the ufs object's one symbol named pvn_vptrunc renamed ufs_vptrunz -- a same-length .strtab string,
#      the only occurrence of the name in the file, 4 bytes changed;
#   3. ld -r of the two;
#   4. HARD CHECK, refusing: ufs_vptrunz defined once, qz_magic, ufs_itrunc its only caller and no longer a
#      caller of pvn_vptrunc, ufs_vptrunz a caller of pvn_vptrunc.  A lost rename leaves quirk 91 in place
#      and links cleanly.
#
# usage: sh tools/ufs-tailzero.sh <ufs object> <output>
#   UFS_TAILZERO=0   the output is the input, byte for byte (the -61 module)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"

IN="$1" OUT="$2"
[ -n "$IN" ] && [ -n "$OUT" ] || { echo "usage: sh tools/ufs-tailzero.sh <ufs object> <output>" >&2; exit 2; }
[ -f "$IN" ] || { echo "ERROR: ufs object missing: $IN"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE ' T ufs_itrunc$' || { echo "[FAIL] $IN defines no ufs_itrunc -- not the ufs object"; exit 1; }
if [ "${UFS_TAILZERO:-1}" = 0 ]; then
	cp "$IN" "$OUT"
	echo "[*] UFS_TAILZERO=0 -- the ufs object unchanged, quirk 91 left in place ($(sha256sum "$OUT" | cut -c1-8))"
	exit 0
fi
echo "[*] ufs object: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"

# qz_check FILE -- the binding, in any object that holds the ufs code
qz_check() {
	o="$1"
	[ "$(m68k-linux-gnu-nm "$o" | awk '$3=="ufs_vptrunz" && $2=="T"' | wc -l)" = 1 ] \
		|| { echo "[FAIL] $o does not define ufs_vptrunz once"; exit 1; }
	m68k-linux-gnu-nm "$o" | awk '$3=="qz_magic" && $2=="D" {f=1} END {exit !f}' \
		|| { echo "[FAIL] no qz_magic in $o"; exit 1; }
	calls=$(m68k-linux-gnu-objdump -dr "$o" | awk '/^[0-9a-f]+ <[^>]*>:$/ {fn=substr($2, 2, length($2) - 3)}
		/R_68K_32[ \t]+(pvn_vptrunc|ufs_vptrunz)$/ {print fn ">" $NF}' | LC_ALL=C sort -u)
	echo "$calls" | grep -qx 'ufs_itrunc>ufs_vptrunz' || { echo "[FAIL] ufs_itrunc does not call ufs_vptrunz in $o"; exit 1; }
	! echo "$calls" | grep -qx 'ufs_itrunc>pvn_vptrunc' || { echo "[FAIL] ufs_itrunc still calls pvn_vptrunc in $o"; exit 1; }
	[ "$(echo "$calls" | grep -c '>ufs_vptrunz$')" = 1 ] || { echo "[FAIL] ufs_vptrunz has callers other than ufs_itrunc in $o"; exit 1; }
	echo "$calls" | grep -qx 'ufs_vptrunz>pvn_vptrunc' || { echo "[FAIL] ufs_vptrunz does not call pvn_vptrunc in $o"; exit 1; }
	echo "[OK] ufs tail zeroing bound in $(basename "$o"): ufs_itrunc -> ufs_vptrunz -> pvn_vptrunc, qz_magic"
}

# ---------------------------------------------------------------- 1. the compile and its gates
T="$HERE/build/ufs-tailzero"; rm -rf "$T"; mkdir -p "$T"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
echo "[*] cross-compiling src/ufs_vptrunz.c (-m68040 dialect)"
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/ufs_vptrunz.c" -o "$T/ufs_vptrunz.o"
AMIX_MUL64=keep m68k-cbm-sysv4-gcc $CF -c "$HERE/src/ufs_vptrunz.c" -o "$T/ufs_vptrunz-mul64keep.o"
cmp -s "$T/ufs_vptrunz.o" "$T/ufs_vptrunz-mul64keep.o" \
	|| { echo "[FAIL] ufs_vptrunz.o differs with AMIX_MUL64=keep -- the wrapper rewrote a multiply in it"; exit 1; }
GOT=$(m68k-linux-gnu-nm "$T/ufs_vptrunz.o" | awk '$1=="U" {print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "kzero pvn_vptrunc segkmap segmap_getmap segmap_release" ] || { echo "[FAIL] ufs_vptrunz.o imports '$GOT'"; exit 1; }
GOTX=$(m68k-linux-gnu-nm "$T/ufs_vptrunz.o" | awk '$2 ~ /^[TDB]$/ {print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "qz_calls qz_cold qz_kzfail qz_magic qz_puterr qz_tail ufs_vptrunz" ] \
	|| { echo "[FAIL] ufs_vptrunz.o exports '$GOTX'"; exit 1; }
# its only COMMONs are ufs_inode.h's tentatives, which the ufs object carries as COMMON too
[ "$(m68k-linux-gnu-nm "$T/ufs_vptrunz.o" | awk '$2=="C" {print $3}' | LC_ALL=C sort | tr '\n' ' ')" = "inodeNINODE iuniqtime ufs_inode " ] \
	|| { echo "[FAIL] ufs_vptrunz.o has COMMONs other than ufs_inode.h's"; exit 1; }
LC_ALL=C m68k-linux-gnu-objdump -d "$T/ufs_vptrunz.o" > "$T/ufs_vptrunz.lst"
python3 "$HERE/test-tools/scan060.py" "$T/ufs_vptrunz.lst" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: ufs_vptrunz.o is not CLEAN"; python3 "$HERE/test-tools/scan060.py" "$T/ufs_vptrunz.lst"; exit 1; }
echo "[OK] ufs_vptrunz.o: imports and exports as listed, ufs_inode.h COMMONs only, no multiply rewritten, scan060 CLEAN"

# ---------------------------------------------------------------- 2. the rename
cp "$IN" "$T/ufs-renamed.o"; chmod u+w "$T/ufs-renamed.o"
python3 - "$T/ufs-renamed.o" <<'EOF' || { echo "[FAIL] could not rename pvn_vptrunc in the ufs object"; exit 1; }
import struct, sys
p = sys.argv[1]; b = bytearray(open(p, 'rb').read())
assert b[:4] == b'\x7fELF' and b[4] == 1 and b[5] == 2, 'not ELF32 big-endian'
shoff, = struct.unpack_from('>I', b, 32); shentsize, shnum = struct.unpack_from('>HH', b, 46)
sh = [struct.unpack_from('>IIIIIIIIII', b, shoff + i * shentsize) for i in range(shnum)]
hits = []
for s in sh:
    if s[1] != 2:                      # SHT_SYMTAB: the strings its symbols name
        continue
    stroff = sh[s[6]][4]
    for o in range(s[4], s[4] + s[5], 16):
        name, = struct.unpack_from('>I', b, o)
        if bytes(b[stroff + name:b.index(0, stroff + name)]) == b'pvn_vptrunc':
            hits.append(stroff + name)
assert len(hits) == 1, 'symbols named pvn_vptrunc: %d' % len(hits)
assert b.count(b'pvn_vptrunc') == 1, 'pvn_vptrunc appears elsewhere in the object'
b[hits[0]:hits[0] + 11] = b'ufs_vptrunz'
open(p, 'wb').write(b)
EOF
D=$(cmp -l "$IN" "$T/ufs-renamed.o" | wc -l)
[ "$D" = 4 ] || { echo "[FAIL] the rename changed $D bytes (want 4: pvn_vptrunc -> ufs_vptrunz)"; exit 1; }
echo "[OK] pvn_vptrunc -> ufs_vptrunz: one .strtab string, 4 bytes"

# ---------------------------------------------------------------- 3. the link, 4. the hard check
m68k-cbm-sysv4-ld -r -o "$OUT" "$T/ufs-renamed.o" "$T/ufs_vptrunz.o"
qz_check "$OUT"
echo "[OK] built $OUT (sha256 $(sha256sum "$OUT" | cut -d' ' -f1))"
