#!/bin/sh
# relink-040-carve.sh -- the k46 base without the static ufs and s5 (amix-dlm S5-11, contract C4-6).
#
# A module kernel loads ufs as a core-tier module (tools/fsobj-patch.py's object, wrapped by
# amix-dlm tools/carve.py) and has no s5 (amix-dlm S5-37).  This pass makes their ranges of the
# base dead and zeroes them in place, so no address moves (src/carve_fs040.py):
#   - vfssw loses the ufs and s5 rows (nfstype 12 -> 10), init_tbl loses inoinit;
#   - the relocations inside the ranges go, their .text and .data bytes are zeroed;
#   - every symbol defined there leaves the symbol table, and so do the COMMONs only they use.
# Gates, each refusing: no relocation outside the ranges reaches into them; the private COMMONs are
# gone and are the objects' COMMONs less the core tier; every name of amix-dlm abi/k46/core.list
# (the core tier the modules import) is still defined; everything else is the input's, byte for
# byte and relocation for relocation.
#
# Order: on relink-040.sh's output, before every pass that puts a relocation-free branch across
# the ranges (relink-040-sd4card.sh's bsr.l, the W-D7 probe inject's bra.l):
#
#     carve -> dd -> sd4card -> f4arms -> f6 -> rth1 -> kinfo -> dlm -> fpe
#
# Module kernels only: a static family keeps its filesystems.  The cdfs pass (relink-040-cdfs.sh,
# patch_cdfs_vfssw.py) is not run on a carved base: cdfs is a module there (C4-6 section 2), and
# patch_cdfs_vfssw.py's proof (12 rows, nfstype 12, RFS in row 4) does not hold on one.
# tools/kabi-sidecar.py writes no rootfs= for the result (amix-dlm C3-3 version 6).
#
# usage: sh relink-040-carve.sh [base-kernel] [output]
#   STOCK=<unix>      the stock kernel the base was made from (default $AMIX_ROOT/stand/unix)
#   STOCK_SYS=<dir>   the stock usr/sys tree with fs/ufs/exp and fs/s5/exp
#                     (default build/sysroot-modelb/usr/sys)
#   DLM_REPO, DLM_REV the core revision whose abi/k46/core.list is checked (default: the checkout
#                     and pin of relink-040-dlm.sh, so the two passes read one revision)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"
. "$HERE/tools/dlm-rev.sh"
STOCK="${STOCK:-$AMIX_ROOT/stand/unix}"
. "$HERE/tools/verify-stock.sh"
verify_stock "$STOCK"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-carve}"
STOCK_SYS="${STOCK_SYS:-$HERE/build/sysroot-modelb/usr/sys}"
DLM_REPO="${DLM_REPO:-$HERE/../amix/kernel/dlm}"
DLM_REV="${DLM_REV:-$(sed -n 's/^DLM_REV="\${DLM_REV:-\(.*\)}"$/\1/p' "$HERE/relink-040-dlm.sh")}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
for f in ufs s5; do
	[ -f "$STOCK_SYS/fs/$f/exp" ] || { echo "ERROR: no stock $f object: $STOCK_SYS/fs/$f/exp"; exit 1; }
done
echo "[*] base: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
for s in fpe_vec11 sd4_insert dd_order dlm_ident kinfoopen; do
	echo "$NM_IN" | awk 'NF==3{print $3}' | grep -qx "$s" \
		&& { echo "[FAIL] base already has $s -- this pass runs on relink-040.sh's output, first"; exit 1; }
done
echo "$NM_IN" | grep -qE " T ufsinit\$" \
	|| { echo "[FAIL] base has no ufsinit -- already carved?"; exit 1; }

# ---------------------------------------------------------------- 1. the core tier at the pin
dlm_rev
CORE="$OUT.core.list"
git -C "$DLM_GIT" show "$REV:${DLM_PFX}abi/k46/core.list" > "$CORE"
echo "[*] amix-dlm $(echo "$REV" | cut -c1-7): abi/k46/core.list, $(grep -cv '^#' "$CORE") names"

# ---------------------------------------------------------------- 2. the carve and its gates
echo "[*] carve ufs and s5 (src/carve_fs040.py)"
run_step all python3 "$HERE/src/carve_fs040.py" --stock "$STOCK" \
	--obj ufs="$STOCK_SYS/fs/ufs/exp" --obj s5="$STOCK_SYS/fs/s5/exp" --core-list "$CORE" "$IN" "$OUT"
run_step 1 python3 "$HERE/src/carve_fs040.py" --check --core-list "$CORE" "$OUT"

echo
echo "[*] reloc validation:"
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
WEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $OUT carries weak symbols"; exit 1; }
echo "[OK] built $OUT (sha256 $(sha256sum "$OUT" | cut -d' ' -f1)): ufs and s5 dead and zeroed, no address moved"
