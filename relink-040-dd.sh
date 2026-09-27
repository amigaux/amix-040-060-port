#!/bin/sh
# relink-040-dd.sh -- put dd.c's completion into issue-next-then-iodone order (2026-09-27).
#
# dd.c's interrupt completion calls iodone(bp) and only then issues the unit's next command.
# iodone's callback can resubmit synchronously, so the next command can be issued from inside
# iodone and again by the completion's own trailing call.  The order the fix needs is the other
# one: issue next, then iodone.  src/dd_order040.s explains the defect and the site in full.
#
# dd.c exists here only as a binary and its completion routine is a file-static, so this is not
# an override by name.  Two relocations at the tail of that routine are retargeted onto two
# shims (src/patch_dd_order.py); no stock instruction is re-expressed, the error path that shares
# the tail call is left exactly as it was, and the routine still returns startio's result.
#
# Why two relocations and not one: the 2026-07-31 attempt (src/z3660_glue040.s dd_startio_first,
# still opt-in behind Z3660_DD_ORDER=1 in patch_z3660.py) moved only the iodone call and left the
# stock startio call after it, so with two buffers queued the next command was issued twice.  That
# kernel panicked before the banner; the double issue is a hypothesis for the panic, not an
# established cause, and this pass shares the other candidate (issue-before-iodone on the stock
# A3091 path).  A boot is the acceptance.  docs/DD-COMPLETION-ORDER.md records both shapes.
#
# A post-pass over any finished base of this line, before relink-040-fpe.sh (the FPE link is
# always the last link).  The z3660 and zz9000 passes may run before or after it: none of them
# touches these two relocations unless Z3660_DD_ORDER=1.  The combination fails closed in either
# order: this pass refuses a base carrying the island, and patch_z3660.py refuses a kernel whose
# 0xc0ae no longer names iodone.
#
# usage: sh relink-040-dd.sh [base-kernel] [output]
#   DD_BASE_SHA256=<hex>   refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-dd}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$DD_BASE_SHA256" ] || [ "$DD_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $DD_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
# nm is captured once, so a failing nm stops the build here (set -e) instead of reading as
# "no match" in every guard below.
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " T dd_issue_first\$" \
	&& { echo "[FAIL] base already carries dd_issue_first -- use a base without this pass"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }
echo "$NM_IN" | grep -qE " T iodone\$" \
	|| { echo "[FAIL] iodone is not a global T in $IN"; exit 1; }
NSTARTIO=$(echo "$NM_IN" | awk '$3=="startio"' | wc -l)
[ "$NSTARTIO" = 1 ] || { echo "[FAIL] $NSTARTIO definitions of startio in $IN (want exactly dd.c's one)"; exit 1; }
STARTIO_BIND=$(echo "$NM_IN" | awk '$3=="startio"{print $2}')
echo "      iodone global; startio defined once ($STARTIO_BIND @0x$(echo "$NM_IN" | awk '$3=="startio"{print $1}'))"
# The two sites must still be stock: the island of 2026-07-31 would name dd_startio_first here.
SITES=$(m68k-linux-gnu-readelf -rW "$IN" | awk '/^Relocation section '"'"'\.rela\.text'"'"' /{t=1;next} /^Relocation section/{t=0} t && ($1=="0000c0ae" || $1=="0000c0b8") {print $1, $5, $7}')
[ "$SITES" = "0000c0ae iodone 0
0000c0b8 startio 0" ] || { echo "[FAIL] the two dd.c tail relocations are not stock in $IN:"; echo "$SITES" | sed 's/^/      /'; exit 1; }
echo "      .rela.text 0xc0ae -> iodone, 0xc0b8 -> startio (stock)"

# ---------------------------------------------------------------- 1. the shims
echo "[*] assembling src/dd_order040.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/dd_order040.s" -o "$HERE/build/dd_order040.o"
m68k-linux-gnu-size "$HERE/build/dd_order040.o" | sed 's/^/      /'

echo "[*] the shims' imports must be exactly iodone and startio:"
GOT=$(m68k-linux-gnu-nm "$HERE/build/dd_order040.o" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "iodone startio" ] || { echo "[FAIL] unresolved set is: $GOT"; exit 1; }
DEFS=$(m68k-linux-gnu-nm "$HERE/build/dd_order040.o" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$DEFS" = "dd_issue_first dd_startio_tail" ] || { echo "[FAIL] exported set is: $DEFS"; exit 1; }
for s in dd_issue_first dd_startio_tail; do
	echo "$NM_IN" | awk 'NF==3{print $3}' | grep -qx "$s" \
		&& { echo "[FAIL] $s already exists in $IN"; exit 1; }
done
echo "      imports: $GOT; exports: $DEFS; no collision with the base"

echo "[*] 68060 instruction census of the shims (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$HERE/build/dd_order040.o" > "$HERE/build/dd_order040.lst"
run_step all python3 "$HERE/test-tools/scan060.py" "$HERE/build/dd_order040.lst"
# scan060.py reports, it does not exit non-zero: read its two verdict lines, and refuse a
# report carrying neither or a listing it decoded nothing from (the unit is 14 instructions).
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/dd_order040.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -ge 10 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of dd_order040.lst -- not a listing it understood"; exit 1; }
echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: dd_order040.o is not CLEAN"; exit 1; }

# ---------------------------------------------------------------- 2. the link
STAGE="$HERE/build/unix-stage-dd"
cp "$IN" "$STAGE"
if [ "$STARTIO_BIND" = t ]; then
	echo "[*] globalize dd.c's startio (a single local; the shims call it by name)"
	m68k-linux-gnu-objcopy --globalize-symbol startio "$STAGE"
fi
echo "[*] ld -r: base + dd_order040.o (LAST: it carries the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$HERE/build/dd_order040.o"

for s in dd_issue_first dd_startio_tail startio iodone; do
	m68k-linux-gnu-nm "$OUT" | grep -qE " T $s\$" || { echo "[FAIL] $s is not a global T in $OUT"; exit 1; }
done
[ "$(m68k-linux-gnu-nm "$OUT" | awk '$3=="startio"' | wc -l)" = 1 ] \
	|| { echo "[FAIL] more than one startio in $OUT"; exit 1; }
LEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] shims linked, startio single and global, no unresolved symbols"

# ---------------------------------------------------------------- 3. the two retargets
echo "[*] dd.c ihandle tail: iodone -> dd_issue_first, startio -> dd_startio_tail"
run_step all python3 "$HERE/src/patch_dd_order.py" "$OUT"
SITES=$(m68k-linux-gnu-readelf -rW "$OUT" | awk '/^Relocation section '"'"'\.rela\.text'"'"' /{t=1;next} /^Relocation section/{t=0} t && ($1=="0000c0ae" || $1=="0000c0b8") {print $1, $5, $7}')
[ "$SITES" = "0000c0ae dd_issue_first 0
0000c0b8 dd_startio_tail 0" ] || { echo "[FAIL] retargets not in place:"; echo "$SITES"; exit 1; }
echo "      .rela.text 0xc0ae -> dd_issue_first, 0xc0b8 -> dd_startio_tail"

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
	|| { echo "[FAIL] .text size not 4-aligned -- is dd_order040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     next: the z3660 / zz9000 passes as needed, then relink-040-fpe.sh (always the last link)"
