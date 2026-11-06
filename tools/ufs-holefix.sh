#!/bin/sh
# ufs-holefix.sh -- the ufs module's object with rwip's ufs_bmap call wrapped (KNOWN-ISSUES ISSUE-120).  ON by
# default; UFS_HOLE_FIX=0 copies the object through unchanged.
#
# A page-aligned write of whole pages into a hole in the middle of a file (or into a new block past the end of the
# file) got pagecreate from as_iolock, so ufs_bmap allocated the block alloc-only, neither read nor zeroed, and the
# block's pages the write did not cover read back the disk's old contents.  src/ufs_bmap_hf.c looks the block up
# first and keeps alloc-only only for a block already allocated, so a new block is zero-filled and a rewrite runs as
# stock; see its comment.  The routine is the 030 line's (amix kernel/k30 src/ufs_bmap_hf.c), the same code.
#
# Where it runs: after tools/ufs-tailzero.sh, before amix-dlm's carve.py wrap, whose module build takes the result
# as its object:
#
#     fsobj-patch.py ... usr/sys/fs/ufs/exp -o ufs-exp.k46
#     sh tools/ufs-tailzero.sh ufs-exp.k46 ufs-exp-qz.k46
#     sh tools/ufs-holefix.sh ufs-exp-qz.k46 ufs-exp-hf.k46
#
# The base kernel is not touched, and ufs_bmap's other callers (getpage, putpage, ...) are not retargeted: rwip, in
# the module, is the only one.
#
#   1. src/ufs_bmap_hf.c, cross-compiled -m68040: its imports exactly ufs_bmap, its exports the routine and the
#      ufs_hf_* counters, no COMMONs, no multiply rewritten (AMIX_MUL64=keep gives the same object), scan060 CLEAN;
#   2. ld -r of the ufs object and it;
#   3. tools/bmaphf.py: rwip's one ufs_bmap relocation names ufs_bmap_hf (rwip and the call pinned there);
#   4. HARD CHECK, refusing: rwip calls ufs_bmap_hf and not ufs_bmap, ufs_bmap_hf is its only caller and calls
#      ufs_bmap twice, ufs_hf_magic.  A lost retarget leaves ISSUE-120 in place and links cleanly.
#
# usage: sh tools/ufs-holefix.sh <ufs object> <output>
#   UFS_HOLE_FIX=0   the output is the input, byte for byte (the -64 module)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"

IN="$1" OUT="$2"
[ -n "$IN" ] && [ -n "$OUT" ] || { echo "usage: sh tools/ufs-holefix.sh <ufs object> <output>" >&2; exit 2; }
[ -f "$IN" ] || { echo "ERROR: ufs object missing: $IN"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE ' t rwip$' || { echo "[FAIL] $IN defines no rwip -- not the ufs object"; exit 1; }
if [ "${UFS_HOLE_FIX:-1}" = 0 ]; then
	cp "$IN" "$OUT"
	echo "[*] UFS_HOLE_FIX=0 -- the ufs object unchanged, ISSUE-120 left in place ($(sha256sum "$OUT" | cut -c1-8))"
	exit 0
fi
echo "[*] ufs object: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"

# hf_check FILE -- the binding, in any object that holds the ufs code
hf_check() {
	o="$1"
	[ "$(m68k-linux-gnu-nm "$o" | awk '$3=="ufs_bmap_hf" && $2=="T"' | wc -l)" = 1 ] \
		|| { echo "[FAIL] $o does not define ufs_bmap_hf once"; exit 1; }
	m68k-linux-gnu-nm "$o" | awk '$3=="ufs_hf_magic" && $2=="D" {f=1} END {exit !f}' \
		|| { echo "[FAIL] no ufs_hf_magic in $o"; exit 1; }
	calls=$(m68k-linux-gnu-objdump -dr "$o" | awk '/^[0-9a-f]+ <[^>]*>:$/ {fn=substr($2, 2, length($2) - 3)}
		/R_68K_32[ \t]+ufs_bmap_hf$/ {print fn ">" $NF} /R_68K_32[ \t]+ufs_bmap$/ && fn ~ /^(rwip|ufs_bmap_hf)$/ {print fn ">" $NF}' | LC_ALL=C sort)
	[ "$(echo "$calls" | tr '\n' ' ')" = "rwip>ufs_bmap_hf ufs_bmap_hf>ufs_bmap ufs_bmap_hf>ufs_bmap " ] \
		|| { echo "[FAIL] the ufs_bmap calls of rwip and ufs_bmap_hf in $o are: $(echo "$calls" | tr '\n' ' ')(want rwip>ufs_bmap_hf ufs_bmap_hf>ufs_bmap x2)"; exit 1; }
	python3 "$HERE/tools/bmaphf.py" --check "$o" > /dev/null || { echo "[FAIL] bmaphf.py --check refused $o"; exit 1; }
	echo "[OK] ufs hole fix bound in $(basename "$o"): rwip -> ufs_bmap_hf -> ufs_bmap, ufs_hf_magic"
}

# ---------------------------------------------------------------- 1. the compile and its gates
T="$HERE/build/ufs-holefix"; rm -rf "${T:?}"; mkdir -p "$T"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
echo "[*] cross-compiling src/ufs_bmap_hf.c (-m68040 dialect)"
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/ufs_bmap_hf.c" -o "$T/ufs_bmap_hf.o"
AMIX_MUL64=keep m68k-cbm-sysv4-gcc $CF -c "$HERE/src/ufs_bmap_hf.c" -o "$T/ufs_bmap_hf-mul64keep.o"
cmp -s "$T/ufs_bmap_hf.o" "$T/ufs_bmap_hf-mul64keep.o" \
	|| { echo "[FAIL] ufs_bmap_hf.o differs with AMIX_MUL64=keep -- the wrapper rewrote a multiply in it"; exit 1; }
GOT=$(m68k-linux-gnu-nm "$T/ufs_bmap_hf.o" | awk '$1=="U" {print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "ufs_bmap" ] || { echo "[FAIL] ufs_bmap_hf.o imports '$GOT'"; exit 1; }
GOTX=$(m68k-linux-gnu-nm "$T/ufs_bmap_hf.o" | awk '$2 ~ /^[TDB]$/ {print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "ufs_bmap_hf ufs_hf_calls ufs_hf_holes ufs_hf_kept ufs_hf_magic" ] \
	|| { echo "[FAIL] ufs_bmap_hf.o exports '$GOTX'"; exit 1; }
[ -z "$(m68k-linux-gnu-nm "$T/ufs_bmap_hf.o" | awk '$2=="C"')" ] || { echo "[FAIL] ufs_bmap_hf.o has COMMONs"; exit 1; }
LC_ALL=C m68k-linux-gnu-objdump -d "$T/ufs_bmap_hf.o" > "$T/ufs_bmap_hf.lst"
python3 "$HERE/test-tools/scan060.py" "$T/ufs_bmap_hf.lst" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: ufs_bmap_hf.o is not CLEAN"; python3 "$HERE/test-tools/scan060.py" "$T/ufs_bmap_hf.lst"; exit 1; }
echo "[OK] ufs_bmap_hf.o: imports ufs_bmap only, exports as listed, no COMMONs, no multiply rewritten, scan060 CLEAN"

# ---------------------------------------------------------------- 2. the link, 3. the retarget, 4. the hard check
m68k-cbm-sysv4-ld -r -o "$T/ufs-linked.o" "$IN" "$T/ufs_bmap_hf.o"
cp "$T/ufs-linked.o" "$OUT"
python3 "$HERE/tools/bmaphf.py" "$OUT" || { rm -f "$OUT"; echo "[FAIL] bmaphf.py refused the linked object"; exit 1; }
D=$(cmp -l "$T/ufs-linked.o" "$OUT" | wc -l)
[ "$D" -ge 1 ] && [ "$D" -le 3 ] || { rm -f "$OUT"; echo "[FAIL] the retarget changed $D bytes (want 1-3: one r_info's symbol index)"; exit 1; }
hf_check "$OUT"
echo "[OK] built $OUT (sha256 $(sha256sum "$OUT" | cut -d' ' -f1))"
