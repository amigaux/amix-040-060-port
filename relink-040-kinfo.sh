#!/bin/sh
# relink-040-kinfo.sh -- link /dev/kinfo, the kernel's read-only identity record
# (docs/contracts/KINFO.md), into a kernel of this line.
#
#   src/kinfo.c              the record (CPU, line, kabi tag, build id, AXL1 and RTH1 as booted,
#                            boards, sd's card table, memory, modules) and the four entry points
#   src/patch_kinfo_cdevsw.py  cdevsw[53] -> kinfoopen/close/read/write, the row asserted free
#   src/kinfo_tail040.s      the closing .balign 4
#
# Order: after relink-040-rth1.sh (or any pass that exposes sd's controller array as
# sd_queue_tbl: rth1, a4091), before relink-040-fpe.sh, which is always the last link.  The chain
# of this line:  dd -> a3q -> z3660 -> monsw -> zz9000 -> a4091 -> ide -> cdfs -> rth1 -> kinfo -> fpe
#
# Gates: the exact import and export sets, no .rodata, no COMMON, no collision with the base,
# scan060 CLEAN, the cdevsw row asserted free and re-checked.
#
# usage: sh relink-040-kinfo.sh [base-kernel] [output]
#   KINFO_BASE_SHA256=<hex>  refuse any base but that one
#   DLM=1                    the module kernel: -DKINFO_DLM (the module list from the core's
#                            dlm_kinfo_list() on every read) and kabi $KINFO_KABI; the base is
#                            relink-040-rth1.sh's DLM=1 output.  dlm_kinfo_list and dlm_marc_post
#                            stay open until relink-040-dlm.sh links the core, the next pass
#   KINFO_KABI=<tag>         the kabi tag (default: static, or k46.1.3 with DLM=1; it must equal
#                            relink-040-dlm.sh's DLM_KABI)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040-rth1}"
OUT="${2:-$HERE/build/unix-040-kinfo}"
MAJOR=53
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$KINFO_BASE_SHA256" ] || [ "$KINFO_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $KINFO_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
DLM="${DLM:-0}"
case $DLM in
0) KINFO_KABI="${KINFO_KABI:-static}" DCF= PEND= ;;
1) KINFO_KABI="${KINFO_KABI:-k46.1.3}" DCF=-DKINFO_DLM PEND="dlm_kinfo_list dlm_marc_post" ;;
*) echo "ERROR: DLM is 0 or 1"; exit 1 ;;
esac
case $KINFO_KABI in ""|*[!a-z0-9.]*) echo "ERROR: KINFO_KABI '$KINFO_KABI' (a-z 0-9 . only)"; exit 1;; esac
[ ${#KINFO_KABI} -le 23 ] || { echo "ERROR: KINFO_KABI longer than 23"; exit 1; }
echo "      kabi: $KINFO_KABI$([ $DLM = 1 ] && echo "; DLM=1: the module list from dlm_kinfo_list()")"
NM_IN=$(m68k-linux-gnu-nm "$IN")
if [ $DLM = 1 ]; then
	U=$(echo "$NM_IN" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}' | tr '\n' ' ' | sed 's/ $//')
	[ "$U" = dlm_marc_post ] || { echo "[FAIL] DLM=1 wants the base of relink-040-rth1.sh DLM=1 (open: dlm_marc_post), it has: ${U:-nothing open}"; exit 1; }
fi
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] kinfoopen\$" \
	&& { echo "[FAIL] base already has kinfo linked -- use a base without this pass"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base"; exit 1; }
for s in bootinfo buildid chipmem cputype VSIZOFMEM; do
	echo "$NM_IN" | grep -qE " D $s\$" || { echo "[FAIL] base has no global .data $s"; exit 1; }
done
echo "$NM_IN" | grep -qE " [BD] sd_queue_tbl\$" \
	|| { echo "[FAIL] base does not expose sd_queue_tbl -- run relink-040-rth1.sh first"; exit 1; }
# a relink-040-sd4card.sh base: the card table has four slots (kinfo.c's SDCARDS)
SD4=
echo "$NM_IN" | grep -qE " T sd4_insert\$" && SD4=-DSDCARDS=4
[ -z "$SD4" ] || echo "      sd4card: four cards in the base -- kinfo.c with -DSDCARDS=4"
RC=0
python3 "$HERE/src/patch_kinfo_cdevsw.py" --check "$IN" "$MAJOR" > "$HERE/build/kinfo-row.log" 2>&1 || RC=$?
sed 's/^/      /' "$HERE/build/kinfo-row.log"
[ $RC = 1 ] || { echo "[FAIL] cdevsw[$MAJOR] is not a free row in the base (check exit $RC)"; exit 1; }

# ---------------------------------------------------------------- 1. the compile and its gates
echo "[*] cross-compiling src/kinfo.c (-m68040 dialect)"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
OBJ="$HERE/build/kinfo.o"
m68k-cbm-sysv4-gcc $CF $DCF $SD4 -DKINFO_KABI=\"$KINFO_KABI\" -c "$HERE/src/kinfo.c" -o "$OBJ"
m68k-linux-gnu-size "$OBJ" | sed 's/^/      /'
M=$(m68k-linux-gnu-readelf -SW "$OBJ" | awk '{gsub(/[][]/,"")} $2 ~ /^\.rodata/ {print $2}')
[ -z "$M" ] || { echo "[FAIL] kinfo.o carries $M -- the image has .text and .data only"; exit 1; }

echo "[*] 68060 instruction census (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" > "$HERE/build/kinfo.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/kinfo.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 100 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of kinfo.lst -- not a listing it understood"; exit 1; }
echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: kinfo.o is not CLEAN"; echo "$SCAN"; exit 1; }
echo "      [OK]   scan060 CLEAN ($SCANLINES decoded lines)"

echo "[*] imports and exports must be exactly these:"
WANT=$(echo VSIZOFMEM bootinfo buildid chipmem cputype sd_queue_tbl sdopen stext uiomove ${DCF:+dlm_kinfo_list} | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
GOT=$(m68k-linux-gnu-nm "$OBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
WANTX="kinfo_kabi kinfoclose kinfoopen kinforead kinfowrite"
GOTX=$(m68k-linux-gnu-nm "$OBJ" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "$WANTX" ] || { echo "[FAIL] exported set is: $GOTX"; echo "       expected:        $WANTX"; exit 1; }
echo "      imports: $GOT"
echo "      exports: $GOTX"
COMMONS=$(m68k-linux-gnu-nm "$OBJ" | awk '$2=="C"{print $3}')
[ -z "$COMMONS" ] || { echo "[FAIL] kinfo.o has COMMON symbols"; exit 1; }
DUP=$(for s in $GOTX; do echo "$NM_IN" | awk -v s="$s" 'NF==3 && $3==s{print s}'; done)
[ -z "$DUP" ] || { echo "[FAIL] kinfo.o defines names the base already has: $DUP"; exit 1; }

m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/kinfo_tail040.s" -o "$HERE/build/kinfo_tail040.o"

# ---------------------------------------------------------------- 2. the link
echo "[*] ld -r: base + kinfo.o + kinfo_tail040.o (LAST: the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$IN" "$OBJ" "$HERE/build/kinfo_tail040.o"
NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in $GOTX; do
	echo "$NM_OUT" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s not a global definition in $OUT"; exit 1; }
done
LEAK=$(echo "$NM_OUT" | awk -v p=" $PEND " '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" && index(p, " " $2 " ")==0 {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
[ -z "$PEND" ] && echo "[OK] no unresolved symbols" || echo "[OK] no unresolved symbols but $PEND (the core's)"
KK=$(python3 - "$OUT" <<'PY'
import subprocess, sys
f = sys.argv[1]
nm = subprocess.run(['m68k-linux-gnu-nm', f], capture_output=True, text=True).stdout.split()
o = int(nm[nm.index('kinfo_kabi') - 2], 16)
sh = subprocess.run(['m68k-linux-gnu-readelf', '-SW', f], capture_output=True, text=True).stdout
for l in sh.replace('[ ', '[').split('\n'):
    p = l.replace('[', ' ').replace(']', ' ').split()
    if len(p) > 6 and p[1] == '.data':
        b = open(f, 'rb').read()[int(p[4], 16) + o:][:24]
print(b.split(b'\0')[0].decode())
PY
)
[ "$KK" = "$KINFO_KABI" ] && echo "[OK] kinfo_kabi in the image: $KK" || { echo "[FAIL] kinfo_kabi in the image is '$KK', not $KINFO_KABI"; exit 1; }

# ---------------------------------------------------------------- 3. registration
echo "[*] cdevsw[$MAJOR] -> kinfoopen/close/read/write (major $MAJOR = /dev/kinfo)"
run_step all python3 "$HERE/src/patch_kinfo_cdevsw.py" "$OUT" "$MAJOR"
run_step all python3 "$HERE/src/patch_kinfo_cdevsw.py" --check "$OUT" "$MAJOR"

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
	|| { echo "[FAIL] .text size not 4-aligned -- is kinfo_tail040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" ${PEND:+--pending $(echo $PEND | tr ' ' ,)} "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     node:  mknod /dev/kinfo c $MAJOR 0; chmod 0444 /dev/kinfo"
echo "     next:  relink-040-fpe.sh (always the last link)"
