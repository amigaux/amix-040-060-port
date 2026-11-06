#!/bin/sh
# ufs-holefix.sh -- the ufs module's object with rwip's as_iolock call wrapped (KNOWN-ISSUES ISSUE-120).  ON by
# default; UFS_HOLE_FIX=0 copies the object through unchanged.
#
# A page-aligned write of whole pages into a hole in the middle of a file (or into a new block past the end of the
# file, not starting at the block) got pagecreate from as_iolock, so ufs_bmap allocated the block alloc-only, neither
# read nor zeroed, and the block's pages the write did not cover read back the disk's old contents.
# src/as_iolock_ufs.c keeps pagecreate only for a write that starts at the 8 KiB window and covers it or runs to the
# end of the file (Solaris's rule); see its comment.  The routine is the 030 line's (amix kernel/k30
# src/as_iolock_ufs.c), the same code.
#
# Where it runs: after tools/ufs-tailzero.sh, before amix-dlm's carve.py wrap, whose module build takes the result
# as its object:
#
#     fsobj-patch.py ... usr/sys/fs/ufs/exp -o ufs-exp.k46
#     sh tools/ufs-tailzero.sh ufs-exp.k46 ufs-exp-qz.k46
#     sh tools/ufs-holefix.sh ufs-exp-qz.k46 ufs-exp-hf.k46
#
# The base kernel is not touched: as_iolock is unchanged, and rwip, in the module, is the only caller retargeted.
#
#   1. src/as_iolock_ufs.c, cross-compiled -m68040: its imports exactly as_iolock, its exports the routine and the
#      ufs_pc_* counters, no COMMONs, no multiply rewritten (AMIX_MUL64=keep gives the same object), scan060 CLEAN;
#   2. ld -r of the ufs object and it;
#   3. tools/iolockufs.py: rwip's one as_iolock relocation names as_iolock_ufs (rwip and the call pinned there);
#   4. HARD CHECK, refusing: rwip calls as_iolock_ufs and not as_iolock, as_iolock_ufs is its only caller and calls
#      as_iolock, ufs_pc_magic.  A lost retarget leaves ISSUE-120 in place and links cleanly.
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
	[ "$(m68k-linux-gnu-nm "$o" | awk '$3=="as_iolock_ufs" && $2=="T"' | wc -l)" = 1 ] \
		|| { echo "[FAIL] $o does not define as_iolock_ufs once"; exit 1; }
	m68k-linux-gnu-nm "$o" | awk '$3=="ufs_pc_magic" && $2=="D" {f=1} END {exit !f}' \
		|| { echo "[FAIL] no ufs_pc_magic in $o"; exit 1; }
	calls=$(m68k-linux-gnu-objdump -dr "$o" | awk '/^[0-9a-f]+ <[^>]*>:$/ {fn=substr($2, 2, length($2) - 3)}
		/R_68K_32[ \t]+(as_iolock|as_iolock_ufs)$/ {print fn ">" $NF}' | LC_ALL=C sort)
	[ "$(echo "$calls" | tr '\n' ' ')" = "as_iolock_ufs>as_iolock rwip>as_iolock_ufs " ] \
		|| { echo "[FAIL] the as_iolock calls in $o are: $(echo "$calls" | tr '\n' ' ')(want as_iolock_ufs>as_iolock rwip>as_iolock_ufs)"; exit 1; }
	python3 "$HERE/tools/iolockufs.py" --check "$o" > /dev/null || { echo "[FAIL] iolockufs.py --check refused $o"; exit 1; }
	echo "[OK] ufs hole fix bound in $(basename "$o"): rwip -> as_iolock_ufs -> as_iolock, ufs_pc_magic"
}

# ---------------------------------------------------------------- 1. the compile and its gates
T="$HERE/build/ufs-holefix"; rm -rf "${T:?}"; mkdir -p "$T"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
echo "[*] cross-compiling src/as_iolock_ufs.c (-m68040 dialect)"
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/as_iolock_ufs.c" -o "$T/as_iolock_ufs.o"
AMIX_MUL64=keep m68k-cbm-sysv4-gcc $CF -c "$HERE/src/as_iolock_ufs.c" -o "$T/as_iolock_ufs-mul64keep.o"
cmp -s "$T/as_iolock_ufs.o" "$T/as_iolock_ufs-mul64keep.o" \
	|| { echo "[FAIL] as_iolock_ufs.o differs with AMIX_MUL64=keep -- the wrapper rewrote a multiply in it"; exit 1; }
GOT=$(m68k-linux-gnu-nm "$T/as_iolock_ufs.o" | awk '$1=="U" {print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "as_iolock" ] || { echo "[FAIL] as_iolock_ufs.o imports '$GOT'"; exit 1; }
GOTX=$(m68k-linux-gnu-nm "$T/as_iolock_ufs.o" | awk '$2 ~ /^[TDB]$/ {print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "as_iolock_ufs ufs_pc_calls ufs_pc_cleared ufs_pc_kept ufs_pc_magic" ] \
	|| { echo "[FAIL] as_iolock_ufs.o exports '$GOTX'"; exit 1; }
[ -z "$(m68k-linux-gnu-nm "$T/as_iolock_ufs.o" | awk '$2=="C"')" ] || { echo "[FAIL] as_iolock_ufs.o has COMMONs"; exit 1; }
LC_ALL=C m68k-linux-gnu-objdump -d "$T/as_iolock_ufs.o" > "$T/as_iolock_ufs.lst"
python3 "$HERE/test-tools/scan060.py" "$T/as_iolock_ufs.lst" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: as_iolock_ufs.o is not CLEAN"; python3 "$HERE/test-tools/scan060.py" "$T/as_iolock_ufs.lst"; exit 1; }
echo "[OK] as_iolock_ufs.o: imports as_iolock only, exports as listed, no COMMONs, no multiply rewritten, scan060 CLEAN"

# ---------------------------------------------------------------- 2. the link, 3. the retarget, 4. the hard check
m68k-cbm-sysv4-ld -r -o "$T/ufs-linked.o" "$IN" "$T/as_iolock_ufs.o"
cp "$T/ufs-linked.o" "$OUT"
python3 "$HERE/tools/iolockufs.py" "$OUT" || { rm -f "$OUT"; echo "[FAIL] iolockufs.py refused the linked object"; exit 1; }
D=$(cmp -l "$T/ufs-linked.o" "$OUT" | wc -l)
[ "$D" -ge 1 ] && [ "$D" -le 3 ] || { rm -f "$OUT"; echo "[FAIL] the retarget changed $D bytes (want 1-3: one r_info's symbol index)"; exit 1; }
hf_check "$OUT"
echo "[OK] built $OUT (sha256 $(sha256sum "$OUT" | cut -d' ' -f1))"
