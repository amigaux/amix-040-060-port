#!/bin/sh
# relink-040-ttcompat.sh -- EXPLICIT: clear the three ttcompat state fields the stock open leaves
# uninitialised (DRIVER-LINE-7, src/patch_ttcompat_init.py; 2026-10-05).
#
# Since r6 (owner's decision, 2026-10-05) the fix is DEFAULT: relink-040-fpe.sh applies it in its
# step 8.6 to every kernel, before it stamps the build id (TTCOMPAT_INIT=0 opts out).  This pass stays
# for applying it explicitly earlier in a chain; fpe then reports [skip].  Like fpe's step, it must run
# BEFORE the build id is stamped.  It links nothing; it is a same-length byte patch located by symbol.
#
# usage: sh relink-040-ttcompat.sh [base-kernel] [output]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-ttcompat}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
echo "[*] base: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE (and its build id) -- run this pass BEFORE relink-040-fpe.sh"; exit 1; }
[ "$IN" = "$OUT" ] || cp "$IN" "$OUT"
run_step all python3 "$HERE/src/patch_ttcompat_init.py" "$OUT"
run_step all python3 "$HERE/src/patch_ttcompat_init.py" --check "$OUT"
D=$(cmp -l "$IN" "$OUT" | wc -l)
echo "      bytes changed against the input: $D (at most 64, inside ttcompatopen)"
[ "$D" -le 64 ] || { echo "[FAIL] more than the 64-byte span changed"; exit 1; }
echo "[OK] built $OUT"
echo "     next:  relink-040-fpe.sh (always the last link; it stamps the build id)"
