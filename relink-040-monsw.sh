#!/bin/sh
# relink-040-monsw.sh -- link /dev/monsw, the card-independent monitor switch, into a kernel of
# this line (P-8, 2026-09-28).
#
#   src/monsw.c          the driver and the kernel API card drivers call (monsw_set,
#                        monsw_register/unregister, monsw_lastclose); sys/monsw.h says what
#                        the switch value means and where it comes from
#   src/parinit_monsw.s  monswinit() from the parallel-port init hook
#
# Registration: cdevsw[MONSW_MAJOR] (default 52, asserted free on the WHOLE row) d_open/d_close/d_ioctl ->
# monswopen/close/ioctl (src/patch_monsw_cdevsw.py).  The node is `mknod /dev/monsw c 52 0`.
# Not 50: that row is the SAD STREAMS driver's (d_str = sadinfo, /dev/sad/*), which a test of the
# ten function records alone took for free (PO-09).
#
# The init hook chains to whatever strong parinit the base carries, read from nm of the base
# and exposed as parinit_monsw_orig -- the zz9000 pass's way, so the order is free relative to
# zz9000.  It must run AFTER relink-040-z3660.sh, whose glue assumes the stock parinit; and
# BEFORE any pass whose driver imports monsw_* (so, once the RTG driver calls monsw_register,
# before relink-040-zz9000.sh).  The chain of this line: dd -> z3660 -> monsw -> zz9000 -> fpe.
#
# Gates as for zz9000: the exact import set, the exact export set, no COMMON, no collision
# with the base, scan060 CLEAN, the T-9 G1/G2, and an SR presence check -- monsw_set and
# monsw_update each raise to IPL 4 (`movew #9216,%sr`) and restore.
#
# usage: sh relink-040-monsw.sh [base-kernel] [output]
#   MONSW_MAJOR=<n>          the cdevsw row (default 52)
#   MONSW_BASE_SHA256=<hex>  refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-monsw}"
MAJOR="${MONSW_MAJOR:-52}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$MONSW_BASE_SHA256" ] || [ "$MONSW_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $MONSW_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] monswinit\$" \
	&& { echo "[FAIL] base already has monsw linked -- use a base without this pass"; exit 1; }
echo "$NM_IN" | grep -qE " parinit_monsw_orig\$" \
	&& { echo "[FAIL] base already carries parinit_monsw_orig"; exit 1; }
echo "$NM_IN" | awk '$1=="U"{print $2}' | grep -qE '^monsw_' \
	&& { echo "[FAIL] base imports monsw_* unresolved -- a driver that needs monsw was linked before this pass"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }
PARINIT_CUR=$(echo "$NM_IN" | awk '$3=="parinit" && $2=="T"{print $1}')
[ "$(echo "$PARINIT_CUR" | wc -w)" = 1 ] || { echo "[FAIL] want exactly one strong parinit in $IN, found: $PARINIT_CUR"; exit 1; }
PARINIT_STOCK=$(echo "$NM_IN" | awk '$3=="parinit_orig" && $2=="T"{print $1}')
echo "      parinit @0x$PARINIT_CUR$([ -n "$PARINIT_STOCK" ] && echo " (a wrapper; stock body parinit_orig @0x$PARINIT_STOCK)")"

# ---------------------------------------------------------------- 1. the header set
echo "[*] Model-B header set (mirror sysroot + geometry probe; installs sys/monsw.h)"
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'
AMIX_SYSROOT="$HERE/build/sysroot-modelb"
export AMIX_SYSROOT
cmp -s "$HERE/src/sys/monsw.h" "$AMIX_SYSROOT/usr/include/sys/monsw.h" \
	|| { echo "[FAIL] the sysroot's sys/monsw.h is not src/sys/monsw.h"; exit 1; }

# ---------------------------------------------------------------- 2. the compile and its gates
echo "[*] cross-compiling src/monsw.c (-m68040 dialect, Model-B headers)"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
OBJ="$HERE/build/monsw.o"
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/monsw.c" -o "$OBJ"
m68k-linux-gnu-size "$OBJ" | sed 's/^/      /'
M=$(m68k-linux-gnu-readelf -SW "$OBJ" | awk '{gsub(/[][]/,"")} $2 ~ /^\.rodata/ {print $2}')
[ -z "$M" ] || { echo "[FAIL] monsw.o carries $M -- the image has .text and .data only"; exit 1; }

# T-9: G1 = the macro dump keeps `volatile`; G2 = every function that raises the mask writes
# %sr.  The mask is the file's own MONSW_SPLTTY/MONSW_SPLX, asm that leaves no name behind
# after preprocessing, so the gate counts it in the raw source.
echo "[*] T-9 gates G1/G2"
run_step all python3 "$HERE/tools/spl-gate.py" --object "$OBJ" --source "$HERE/src/monsw.c" \
	--cflags "$CF" --macro MONSW_SPLTTY --macro MONSW_SPLX
# ... and presence, by name: the two functions that touch the port raise to IPL 4 and restore.
LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" > "$HERE/build/monsw.lst"
for f in monsw_set monsw_update; do
	R=$(awk -v f="<$f>:" '$2==f{t=1;next} /^[0-9a-f]+ </{t=0} t' "$HERE/build/monsw.lst" | grep -c 'movew #9216,%sr' || true)
	W=$(awk -v f="<$f>:" '$2==f{t=1;next} /^[0-9a-f]+ </{t=0} t' "$HERE/build/monsw.lst" | grep -c ',%sr' || true)
	[ "$R" = 1 ] && [ "$W" = 2 ] \
		|| { echo "[FAIL] $f: $R IPL-4 raise(s), $W SR write(s) -- want 1 and 2 (T-9)"; exit 1; }
	echo "      [OK]   $f raises to IPL 4 and restores (2 SR writes)"
done

echo "[*] 68060 instruction census (kernel mode: nothing emulates a hit)"
run_step all python3 "$HERE/test-tools/scan060.py" "$HERE/build/monsw.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/monsw.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 100 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of monsw.lst -- not a listing it understood"; exit 1; }
echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: monsw.o is not CLEAN"; exit 1; }

echo "[*] imports and exports must be exactly these:"
WANT="copyout drv_priv printf"
GOT=$(m68k-linux-gnu-nm "$OBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
WANTX="monsw_config monsw_lastclose monsw_register monsw_set monsw_unregister monswclose monswinit monswioctl monswopen"
GOTX=$(m68k-linux-gnu-nm "$OBJ" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOTX" = "$WANTX" ] || { echo "[FAIL] exported set is: $GOTX"; echo "       expected:        $WANTX"; exit 1; }
echo "      imports: $GOT"
echo "      exports: $GOTX"
COMMONS=$(m68k-linux-gnu-nm "$OBJ" | awk '$2=="C"{print $3}')
[ -z "$COMMONS" ] || { echo "[FAIL] monsw.o has COMMON symbols"; exit 1; }
DUP=$(for s in $GOTX; do echo "$NM_IN" | awk -v s="$s" 'NF==3 && $3==s{print s}'; done)
[ -z "$DUP" ] || { echo "[FAIL] monsw.o defines names the base already has: $DUP"; exit 1; }
echo "      no COMMON symbols; no definition collides with a name in the base"

echo "[*] assembling the parinit wrapper"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/parinit_monsw.s" -o "$HERE/build/parinit_monsw.o"

# ---------------------------------------------------------------- 3. the link
echo "[*] weaken the base's parinit, expose it as parinit_monsw_orig @0x$PARINIT_CUR"
STAGE="$HERE/build/unix-stage-monsw"
cp "$IN" "$STAGE"
m68k-linux-gnu-objcopy --weaken-symbol parinit \
	--add-symbol parinit_monsw_orig=.text:0x${PARINIT_CUR},function,global "$STAGE"
echo "[*] ld -r: base + monsw.o + parinit_monsw.o (wrapper LAST: it carries the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$OBJ" "$HERE/build/parinit_monsw.o"

NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in $GOTX parinit parinit_monsw_orig; do
	echo "$NM_OUT" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s not a global definition in $OUT"; exit 1; }
done
BASETEXT=$(( 0x$(m68k-linux-gnu-readelf -SW "$STAGE" | awk '{gsub(/[][]/,"")} $2==".text"{print $6}') ))
PARINIT_NEW=$(echo "$NM_OUT" | awk '$3=="parinit" && $2=="T"{print $1}')
[ "$(echo "$PARINIT_NEW" | wc -w)" = 1 ] || { echo "[FAIL] expected exactly 1 strong parinit, found: $PARINIT_NEW"; exit 1; }
[ $(( 0x$PARINIT_NEW )) -ge "$BASETEXT" ] || { echo "[FAIL] parinit still resolves into the base at 0x$PARINIT_NEW"; exit 1; }
A=$(echo "$NM_OUT" | awk '$3=="parinit_monsw_orig"{print $1}')
[ "$A" = "$PARINIT_CUR" ] || { echo "[FAIL] parinit_monsw_orig @0x$A != the base's parinit @0x$PARINIT_CUR"; exit 1; }
if [ -n "$PARINIT_STOCK" ]; then
	A=$(echo "$NM_OUT" | awk '$3=="parinit_orig"{print $1}')
	[ "$A" = "$PARINIT_STOCK" ] || { echo "[FAIL] parinit_orig moved: 0x$A != 0x$PARINIT_STOCK"; exit 1; }
fi
echo "      chain: parinit (0x$PARINIT_NEW) -> parinit_monsw_orig (0x$PARINIT_CUR)$([ -n "$PARINIT_STOCK" ] && echo " -> ... -> parinit_orig (0x$PARINIT_STOCK)")"
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# ---------------------------------------------------------------- 4. registration
echo "[*] cdevsw[$MAJOR] -> monswopen/close/ioctl (major $MAJOR = /dev/monsw)"
run_step all python3 "$HERE/src/patch_monsw_cdevsw.py" "$OUT" "$MAJOR"

# ---------------------------------------------------------------- 5. packaging guards
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
	|| { echo "[FAIL] .text size not 4-aligned -- is parinit_monsw.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     node:  mknod /dev/monsw c $MAJOR 0"
echo "     next:  relink-040-zz9000.sh (if wanted), then relink-040-fpe.sh (always the last link)"
