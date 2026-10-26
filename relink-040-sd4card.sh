#!/bin/sh
# relink-040-sd4card.sh -- four disk controllers in the stock sd, dd and ct, in the rank order of
# amix-dlm C4-1 (2026-10-26, Q4-3).
#
# The stock sd layer keeps two controllers (SDCARDS 2) sorted by base address and drops a third;
# dd and ct keep two-row tables and take the card from minor bit 3 alone.  C4-1 gives four cards:
# the card's high bit is minor bit 7, so cards 0-1 keep their minors, cards 2-3 name their disks
# c10-c1f; the order is the rank class (z3660, zorro, mobo, ide), then the base.
#
#   src/sd4card.c        sd_queue_tbl, four slots, and sd4_insert(), the ranked insert
#   src/sdcardbase040.s  sdcardbase() over four cards (--defsym SD4=1)
#   src/sd4card040.s     dd's and ct's four-row tables and the card decodes (LAST: .balign 4)
#   src/patch_sd4card.py the in-place edits: 13 relocations retargeted, sdopen's bound to card < 4,
#                        11 inline decodes replaced by calls of the same length
#
# The rank of a controller comes from the row of sd's table it was found by.  init() hands insert()
# the row's queue function, so sd4_insert() looks it up in the table init() walks, read through
# init's own `lea` and `moveq` operands (sd4_init_tbl, sd4_init_bound, exposed here), so the rows
# the z3660, a4091 and ide passes add later are found the same way.
#
# Order: after relink-040-dd.sh, before every pass that adds sdcardbase or exposes sd_queue_tbl
# (a4091, rth1): this pass defines both.  On a base it has run on, relink-040-rth1.sh and
# relink-040-kinfo.sh build their four-card form; on any other base nothing of theirs changes.
#
#     dd -> sd4card -> z3660 -> [a4091] -> f4arms -> f6 -> rth1 -> kinfo -> [dlm] -> fpe
#
# usage: sh relink-040-sd4card.sh [base-kernel] [output]
#   SD4_BASE_SHA256=<hex>   refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-sd4card}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$SD4_BASE_SHA256" ] || [ "$SD4_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $SD4_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " T sd4_insert\$" \
	&& { echo "[FAIL] base already carries sd4_insert -- use a base without this pass"; exit 1; }
for s in sdcardbase sd_queue_tbl sd4_init_tbl sd4_init_bound; do
	echo "$NM_IN" | awk 'NF==3{print $3}' | grep -qx "$s" \
		&& { echo "[FAIL] base already has $s -- this pass runs before the a4091 and rth1 passes"; exit 1; }
done
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }
# init()'s two operands the ranked insert reads: `lea <table>,%a3` at 0xd74a, `moveq #N,%d1` at 0xd79e
OPS=$(m68k-linux-gnu-objdump -d --start-address=0xd74a --stop-address=0xd7a0 "$IN" \
	| awk '$1=="d74a:" || $1=="d79e:" {print $2 $3}' | tr '\n' ' ')
case "$OPS" in "47f90000 72"*) ;; *) echo "[FAIL] init's lea/moveq are not at 0xd74a/0xd79e: $OPS"; exit 1;; esac
echo "      sd: init's lea @0xd74a and moveq @0xd79e in place; no sdcardbase, no sd_queue_tbl yet"

# ---------------------------------------------------------------- 1. the objects
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
echo "[*] cross-compiling src/sd4card.c (-m68040)"
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/sd4card.c" -o "$HERE/build/sd4card.o"
m68k-cbm-sysv4-gcc -m68040 -Wa,--defsym,SD4=1 -c "$HERE/src/sdcardbase040.s" -o "$HERE/build/sdcardbase040-sd4.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/sd4card040.s" -o "$HERE/build/sd4card040.o"
OBJS="$HERE/build/sd4card.o $HERE/build/sdcardbase040-sd4.o $HERE/build/sd4card040.o"
for o in $OBJS; do m68k-linux-gnu-size "$o" | sed -n 2p | sed 's/^/      /'; done

echo "[*] imports and exports must be exactly these:"
WANT="printf sd4_init_bound sd4_init_tbl"
GOT=$(m68k-linux-gnu-nm $OBJS | awk '$1=="U"{print $2}' | grep -vx 'sd_queue_tbl' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
WANTX="sd4_cttab sd4_ddtab sd4_dev_d0d1 sd4_dev_d0d2 sd4_dev_d0d5 sd4_dev_d1d2 sd4_dev_d1d3 sd4_dev_d1d4 sd4_idx_d1d2 sd4_insert sd4_rank sd_queue_tbl sdcardbase"
GOTX=$(m68k-linux-gnu-nm $OBJS | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "$WANTX" ] || { echo "[FAIL] exported set is: $GOTX"; echo "       expected:        $WANTX"; exit 1; }
M=$(m68k-linux-gnu-nm $OBJS | awk '$2 ~ /^[BbCc]$/{print $3}')
[ -z "$M" ] || { echo "[FAIL] .bss or COMMON in the objects: $M -- the image has .text and .data only"; exit 1; }
DUP=$(for s in $GOTX; do echo "$NM_IN" | awk -v s="$s" 'NF==3 && $3==s'; done)
[ -z "$DUP" ] || { echo "[FAIL] the objects define names the base already has: $DUP"; exit 1; }
echo "      imports: $GOT (+ sd_queue_tbl, sdcardbase's, from sd4card.o)"
echo "      exports: $GOTX"

echo "[*] 68060 instruction census of the objects"
for o in $OBJS; do
	L="${o%.o}.lst"
	LC_ALL=C m68k-linux-gnu-objdump -d "$o" > "$L"
	SCAN=$(python3 "$HERE/test-tools/scan060.py" "$L")
	echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
		|| { echo "$SCAN"; echo "[FAIL] scan060: $(basename "$o") is not CLEAN"; exit 1; }
	echo "      CLEAN  $(basename "$o")"
done

# ---------------------------------------------------------------- 2. the link
STAGE="$HERE/build/unix-stage-sd4card"
cp "$IN" "$STAGE"
echo "[*] expose init's operands: sd4_init_tbl = .text 0xd74c (the lea's table), sd4_init_bound = .text 0xd79f"
m68k-linux-gnu-objcopy --add-symbol sd4_init_tbl=.text:0xd74c,object,global \
	--add-symbol sd4_init_bound=.text:0xd79f,object,global "$STAGE"
echo "[*] ld -r: base + sd4card.o + sdcardbase040-sd4.o + sd4card040.o (LAST: the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" $OBJS
LEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }

# ---------------------------------------------------------------- 3. the edits
echo "[*] sd, dd and ct to four cards (src/patch_sd4card.py)"
run_step all python3 "$HERE/src/patch_sd4card.py" "$OUT"
run_step all python3 "$HERE/src/patch_sd4card.py" --check "$OUT"

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
	|| { echo "[FAIL] .text size not 4-aligned -- is sd4card040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     next: the z3660 (and a4091) passes, then rth1 and kinfo build their four-card form;"
echo "           relink-040-fpe.sh is always the last link"
