#!/bin/sh
# relink-040-ddcensus.sh -- DIAGNOSTIC ONLY: a census of disk requests whose buffer crosses a page,
# split by identity region vs kvseg, with a ring of the kvseg ones (2026-10-03, P-15 DI-1 follow-up).
#
#   *** NEVER IN A SHIPPING CHAIN (K1, KD060-Z or any released family).  It exists to make the
#   *** positive statement "zero kvseg buffers straddled scattered frames" on the rig and the
#   *** Bench; kerntools builds a separate diagnostic chain for that.
#
# Why: the host adapter is handed ONE physical address per request and moves the length
# linearly from it, so a buffer that crosses a page is only right if its pages are consecutive
# frames.  In the identity region (va < 0x40000000) they are by construction; in kvseg they need
# not be.  The Z3660 driver's z3660_pagecross_n sees only the physical address and cannot tell the
# two apart -- KD060-Z-CD's 11 were all getrdb's identity-mapped static buffer (harmless).
# src/ddcensus040.s explains the hook, the counters and the ring layout; src/patch_ddcensus.py
# retargets dd startio's one vtop call (.text 0xc10a) onto it.
#
# A post-pass over any finished base of this line, before relink-040-fpe.sh.  It touches only
# startio's vtop relocation, which no other pass edits.
#
# usage: sh relink-040-ddcensus.sh [base-kernel] [output]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-ddcensus}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
echo "[*] DIAGNOSTIC pass (never shipped): base $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -c1-16))"

NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " T dd_vtop_census\$" \
	&& { echo "[FAIL] base already carries the census"; exit 1; }
echo "$NM_IN" | grep -qE " T vtop\$" || { echo "[FAIL] vtop is not a global T in $IN"; exit 1; }

echo "[*] assembling src/ddcensus040.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/ddcensus040.s" -o "$HERE/build/ddcensus040.o"
GOT=$(m68k-linux-gnu-nm "$HERE/build/ddcensus040.o" | awk '$1=="U"{print $2}' | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "vtop" ] || { echo "[FAIL] the census imports: $GOT"; exit 1; }
for s in $(m68k-linux-gnu-nm "$HERE/build/ddcensus040.o" | awk '$2 ~ /^[TD]$/{print $3}'); do
	echo "$NM_IN" | awk 'NF==3{print $3}' | grep -qx "$s" && { echo "[FAIL] $s already exists in $IN"; exit 1; }
done
LC_ALL=C m68k-linux-gnu-objdump -d "$HERE/build/ddcensus040.o" > "$HERE/build/ddcensus040.lst"
python3 "$HERE/test-tools/scan060.py" "$HERE/build/ddcensus040.lst" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: ddcensus040.o is not CLEAN"; exit 1; }
echo "      imports vtop only; scan060 CLEAN"
echo "[*] the census on qemu-m68k (tools/test-ddcensus.sh)"
run_step indent sh "$HERE/tools/test-ddcensus.sh"

echo "[*] ld -r: base + ddcensus040.o (LAST: .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$IN" "$HERE/build/ddcensus040.o"
LEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }

echo "[*] dd startio's vtop -> dd_vtop_census"
run_step all python3 "$HERE/src/patch_ddcensus.py" "$OUT"

CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	END{print to, ts, do_}')
set -- $CONTIG
TSZ=$(( 0x$2 ))
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." || { echo "[FAIL] text/data NOT contiguous"; exit 1; }
[ $((TSZ % 4)) -eq 0 ] && echo "[OK] .text size 0x$(printf %x $TSZ) is 4-aligned." \
	|| { echo "[FAIL] .text size not 4-aligned"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"
echo "     counters (.data symbols, read with kmemdump/adb; offsets from dcn_magic):"
m68k-linux-gnu-nm "$OUT" | awk '$3 ~ /^dcn_/ {print "       " $3 " .data+0x" $1}'
echo "[OK] built $OUT  (DIAGNOSTIC -- never ship)"
echo "     next: relink-040-fpe.sh (always the last link)"
