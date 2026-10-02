#!/bin/sh
# relink-040-a3091q.sh -- keep the A3091 start queue consistent across disconnect and reselect
# (2026-10-02).
#
# The driver-line port of amix-a4091's a3091.c lifecycle fix (be2f5e3): a reselecting unit is
# taken off the start queue, a linked unit is never linked twice, and a drained entry is never
# started.  src/a3091q040.s explains the defect and the three wrappers; src/patch_a3091_queue.py
# retargets the seven call relocations onto them.  The same patch's chip-RAM bounce is NOT
# carried: the SDMAC reaches the accelerator's RAM directly (the base kernel roots through the
# stock a3091 from 0x07000000 and 0x08000000 on real A3000s, STATUS.md), and the coherence the
# bounce supplied as a side effect is the B2 protocol's job on this line (src/dma_cache040.s).
#
# A post-pass over any finished base of this line, before relink-040-fpe.sh (the FPE link is
# always the last link).  It touches only a3091.c's own relocations, which no other driver-line
# pass edits, so its place relative to the dd, z3660, monsw, zz9000 and a4091 passes is free;
# the chains put it right after dd.
#
# usage: sh relink-040-a3091q.sh [base-kernel] [output]
#   A3091Q_OFF=1            build the CONTROL kernel: wrappers linked and retargeted, a3q_on = 0
#   A3091Q_BASE_SHA256=<hex> refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-a3091q}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$A3091Q_BASE_SHA256" ] || [ "$A3091Q_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $A3091Q_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " T a3091q_uqueue\$" \
	&& { echo "[FAIL] base already carries a3091q_uqueue -- use a base without this pass"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }
# What the wrappers call and read, all defined by the base link (relink-040.sh --add-symbol
# aliases and src/dma_cache040.s), at the a3091 addresses this pass was measured against.
for want in "0000cfce T a3091_uqueue" "0000d00c T a3091_startany" \
	    "00003cc8 B a3091_istate" "00003cd8 B a3091_starthead" \
	    "00003cd0 b starttail"; do
	echo "$NM_IN" | grep -qx "$want" || { echo "[FAIL] base lacks '$want'"; exit 1; }
done
echo "$NM_IN" | grep -qE " T dma_a3091_startdma_reconn\$" \
	|| { echo "[FAIL] base lacks the B2 reconnect wrapper dma_a3091_startdma_reconn"; exit 1; }
echo "$NM_IN" | awk 'NF==3{print $3}' | grep -qx a3091_starttail \
	&& { echo "[FAIL] a3091_starttail already exists in $IN"; exit 1; }
# `starttail` is a3091.c's only if the stock uqueue stores through it: the relocation at
# .text 0xcfe4 (a3091 uqueue's `moveal starttail,%a0`) must name the local at .bss 0x3cd0.
TAIL=$(m68k-linux-gnu-readelf -rW "$IN" | awk '/^Relocation section '"'"'\.rela\.text'"'"' /{t=1;next} /^Relocation section/{t=0} t && $1=="0000cfe4" {print $4, $5}')
[ "$TAIL" = "00003cd0 starttail" ] \
	|| { echo "[FAIL] .rela.text 0xcfe4 is '$TAIL', not a3091's starttail at .bss 0x3cd0"; exit 1; }
echo "      a3091 uqueue/startany/istate/starthead aliases present; starttail is .bss 0x3cd0"

# ---------------------------------------------------------------- 1. the wrappers
echo "[*] assembling src/a3091q040.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/a3091q040.s" -o "$HERE/build/a3091q040.o"
m68k-linux-gnu-size "$HERE/build/a3091q040.o" | sed 's/^/      /'
GOT=$(m68k-linux-gnu-nm "$HERE/build/a3091q040.o" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "a3091_istate a3091_startany a3091_starthead a3091_starttail a3091_uqueue dma_a3091_startdma_reconn" ] \
	|| { echo "[FAIL] the wrappers' imports are: $GOT"; exit 1; }
DEFS=$(m68k-linux-gnu-nm "$HERE/build/a3091q040.o" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$DEFS" = "a3091q_resume a3091q_startany a3091q_uqueue a3q_dbl a3q_drop a3q_magic a3q_on a3q_unq a3q_walkcap" ] \
	|| { echo "[FAIL] the wrappers' exports are: $DEFS"; exit 1; }
for s in $DEFS; do
	echo "$NM_IN" | awk 'NF==3{print $3}' | grep -qx "$s" && { echo "[FAIL] $s already exists in $IN"; exit 1; }
done
echo "      imports: $GOT"
echo "      exports: $DEFS; no collision with the base"

echo "[*] 68060 instruction census of the wrappers (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$HERE/build/a3091q040.o" > "$HERE/build/a3091q040.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/a3091q040.lst")
echo "$SCAN" | sed 's/^/      /'
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -ge 40 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of a3091q040.lst -- not a listing it understood"; exit 1; }
echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: a3091q040.o is not CLEAN"; exit 1; }

echo "[*] the wrappers on qemu-m68k, fix on and control (tools/test-a3091q.sh)"
run_step indent sh "$HERE/tools/test-a3091q.sh"

# ---------------------------------------------------------------- 2. the link
STAGE="$HERE/build/unix-stage-a3091q"
cp "$IN" "$STAGE"
echo "[*] alias a3091.c's starttail (a file-static; A2090 and A2091 have their own)"
m68k-linux-gnu-objcopy --add-symbol a3091_starttail=.bss:0x3cd0,object,global "$STAGE"
echo "[*] ld -r: base + a3091q040.o (LAST: it carries the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$HERE/build/a3091q040.o"

NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in a3091q_uqueue a3091q_startany a3091q_resume; do
	echo "$NM_OUT" | grep -qE " T $s\$" || { echo "[FAIL] $s is not a global T in $OUT"; exit 1; }
done
echo "$NM_OUT" | grep -qx "00003cd0 B a3091_starttail" \
	|| { echo "[FAIL] a3091_starttail is not .bss 0x3cd0 in $OUT"; exit 1; }
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] wrappers linked, a3091_starttail aliased, no unresolved symbols"

# ---------------------------------------------------------------- 3. the seven retargets
if [ "${A3091Q_OFF:-0}" = 1 ]; then
	echo "[*] retarget the seven a3091 queue calls; a3q_on = 0 (CONTROL)"
	run_step all python3 "$HERE/src/patch_a3091_queue.py" "$OUT" --off
else
	echo "[*] retarget the seven a3091 queue calls"
	run_step all python3 "$HERE/src/patch_a3091_queue.py" "$OUT"
fi
SITES=$(m68k-linux-gnu-readelf -rW "$OUT" | awk '/^Relocation section '"'"'\.rela\.text'"'"' /{t=1;next} /^Relocation section/{t=0} t && ($1=="0000cfbe" || $1=="0000d1b4" || $1=="0000d1d4" || $1=="0000d2ea" || $1=="0000d002" || $1=="0000d356" || $1=="0000d21a") {print $1, $5}' | LC_ALL=C sort)
[ "$SITES" = "0000cfbe a3091q_uqueue
0000d002 a3091q_startany
0000d1b4 a3091q_uqueue
0000d1d4 a3091q_uqueue
0000d21a a3091q_resume
0000d2ea a3091q_uqueue
0000d356 a3091q_startany" ] || { echo "[FAIL] retargets not in place:"; echo "$SITES" | sed 's/^/      /'; exit 1; }
echo "      seven sites -> a3091q_uqueue x4, a3091q_startany x2, a3091q_resume x1"

# ---------------------------------------------------------------- 4. packaging guards
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	END{print to, ts, do_}')
set -- $CONTIG
TSZ=$(( 0x$2 ))
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." \
	|| { echo "[FAIL] text/data NOT contiguous"; exit 1; }
[ $((TSZ % 4)) -eq 0 ] && echo "[OK] .text size 0x$(printf %x $TSZ) is 4-aligned." \
	|| { echo "[FAIL] .text size not 4-aligned -- is a3091q040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT$( [ "${A3091Q_OFF:-0}" = 1 ] && echo '  (CONTROL: a3q_on = 0)')"
echo "     next: the z3660 / zz9000 / a4091 passes as needed, then relink-040-fpe.sh (always the last link)"
