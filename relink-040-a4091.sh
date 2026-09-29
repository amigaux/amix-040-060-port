#!/bin/sh
# relink-040-a4091.sh -- link the A4091/A4092 53C710 driver into a kernel of this line
# (PO-04, 2026-09-28).
#
#   the amix-a4091 repository   src/a4091-wr.c, built with -DA4091_KVA: its 040/060 arm, which
#                               finds the board only through sd's autocon() lookup, maps both
#                               register pages NCS with dev_kvmap(), and never takes a fixed
#                               address (A4-11)
#
# What this pass adds, and why nothing else:
#
#   a4091_040.o        the driver.  Its one entry point is a4091queue, called through sd's
#                      controller table; it initialises the chip lazily on the first queued
#                      command.  So there is no cdevsw/bdevsw row (the disks are sd's majors,
#                      the card is in the minor) and no init hook.
#   sdcardbase040.o    sdcardbase(card), the recorded AutoConfig base -- the one entry point the
#                      driver needs from sd that the stock sd.o does not have.
#   a4091_scsicard.o   a new controller table, generated from the base's: every existing row by
#                      relocation, then A4091 (0x02020054) and A4092 (0xc0de0001).  The rows go
#                      LAST because sd's insert() keeps two controllers and drops a newcomer.
#   devkvmap040.o      dev_kvmap/dev_kvunmap, unless the base already has them.
#
# and two edits after the link (src/a4091_sd_rows.py patch): the `lea <table>,%a3` relocation
# at .text+0xd74c to the new table, and init()'s loop bound at .text+0xd79f to its row count.
# check_root_family.py then re-reads the result and must find a4091queue among the rows.
#
# Order: after relink-040-z3660.sh (patch_z3660.py requires the lea to still name the stock
# table), before relink-040-fpe.sh (always the last link).  The monsw and zz9000 passes do not
# touch sd and may run before or after it.
#
# usage: sh relink-040-a4091.sh [base-kernel] [output]
#   A4091_REPO=<dir>   the amix-a4091 checkout (default: ../amix-a4091 beside this repository)
#   A4091_REV=<rev>    take the driver from that revision (the log says which).  Default: the pin
#                      below; A4091_REV= (empty) takes the checkout's working tree instead
#   A4091_OPTS="..."   extra driver options.  -DA4091_D42 links the port's D42 DMA-coherence
#                      service (dma_prepare/dma_complete, src/dma_cache040.s, contract
#                      docs/contracts/DMA040-SERVICE-RECORD.md) instead of the driver's local
#                      stubs, and needs a base that exports both
#   A4091_BASE_SHA256=<hex>  refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-a4091}"
REPO="${A4091_REPO:-$HERE/../amix-a4091}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$A4091_BASE_SHA256" ] || [ "$A4091_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $A4091_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] (a4091queue|sdcardbase)\$" \
	&& { echo "[FAIL] base already has a4091queue or sdcardbase -- use a base without this pass"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }
echo "[*] the base's root-storage family"
run_step indent python3 "$HERE/src/check_root_family.py" "$IN"
if echo "$NM_IN" | grep -qE " T dev_kvmap\$"; then
	DEVKV=; echo "      dev_kvmap: in the base"
else
	DEVKV="$HERE/build/devkvmap040.o"; echo "      dev_kvmap: not in the base -- linking src/devkvmap040.s"
fi

# ---------------------------------------------------------------- 1. the header set
echo "[*] Model-B header set (mirror sysroot + geometry probe)"
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'
AMIX_SYSROOT="$HERE/build/sysroot-modelb"
export AMIX_SYSROOT
ALIEN="$AMIX_SYSROOT/usr/sys/amiga/alien"
[ -f "$ALIEN/sd.h" ] && [ -f "$ALIEN/rico.h" ] || { echo "ERROR: sd.h/rico.h not under $ALIEN"; exit 1; }

# ---------------------------------------------------------------- 2. the driver source
SRCDIR="$HERE/build/a4091-src"
rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
FILES="src/a4091-wr.c src/a4091_dmarec.h tools/a4091-widths.py"
# Pinned (PO-16, 2026-09-29): amix-a4091 fa8732a -- the D42 contract's names (4df8332) plus the
# bounce (A4-18): a misaligned FROM_DEVICE transfer of <= 1 KB goes through a static 16-aligned
# buffer and is copied out after dma_complete, > 1 KB is refused with status 0xff, so edge_shared
# stays 0 on this driver.  a4091_kstat's magic is "A4K2" with bounce_n/bounce_toolong after
# bw_mask[SDCARDS].  a4091_040.o e66fef1e with the stub arm, e1f831ce with -DA4091_D42.
A4091_REV="${A4091_REV-fa8732a}"
DEFS="-DA4091_KVA $A4091_OPTS"
if [ -n "$A4091_REV" ]; then
	for f in $FILES; do
		git -C "$REPO" cat-file -e "$A4091_REV:$f" || { echo "ERROR: $f does not exist at $A4091_REV in $REPO"; exit 1; }
		git -C "$REPO" show "$A4091_REV:$f" > "$SRCDIR/$(basename "$f")"
	done
	SRCID="$(git -C "$REPO" rev-parse "$A4091_REV") ($A4091_REV, from the repository)"
else
	echo "[*] A4091_REV empty: taking the working tree of $REPO (not pinned)"
	for f in $FILES; do cp "$REPO/$f" "$SRCDIR/"; done
	SRCID="working tree $REPO"
	HEADREV=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)
	if [ -n "$HEADREV" ]; then
		MOD=$(git -C "$REPO" status --porcelain -- $FILES 2>/dev/null || true)
		SRCID="$SRCID @ $HEADREV"
		[ -z "$MOD" ] || SRCID="$SRCID (MODIFIED)"
	fi
fi
echo "[*] driver source: $SRCID"
sha256sum "$SRCDIR/a4091-wr.c" "$SRCDIR/a4091_dmarec.h" | sed 's/^/      /'

# ---------------------------------------------------------------- 3. the compile and its gates
echo "[*] cross-compiling a4091-wr.c $DEFS (-m68040 dialect, Model-B headers)"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
OBJ="$HERE/build/a4091_040.o"
m68k-cbm-sysv4-gcc $CF $DEFS -I"$ALIEN" -I"$SRCDIR" -c "$SRCDIR/a4091-wr.c" -o "$OBJ"
m68k-linux-gnu-size "$OBJ" | sed 's/^/      /'
sha256sum "$OBJ" | sed 's/^/      /'
M=$(m68k-linux-gnu-readelf -SW "$OBJ" | awk '{gsub(/[][]/,"")} $2 ~ /^\.rodata/ {print $2}')
[ -z "$M" ] || { echo "[FAIL] a4091_040.o carries $M -- the image has .text and .data only"; exit 1; }

echo "[*] page geometry: the compiled bytes, and the same source against the stock 2 KiB headers"
run_step indent sh "$HERE/src/check_page_geometry.sh" "$OBJ"
# The differential compile: the 040 arm maps through dev_kvmap and should compute no page number
# at all, so the stock-header object is expected to be identical.  A difference is printed, not
# refused -- check_page_geometry above is the gate -- but it says where the geometry reaches.
STOCKOBJ="$HERE/build/a4091_040-stockhdr.o"
REAL=$(. "$GCC_CROSS_ENV"; echo "${AMIX_REAL_SYSROOT:-$AMIX_CROSS/m68k-cbm-sysv4/sysroot}")
[ -f "$REAL/usr/sys/amiga/alien/sd.h" ] || { echo "ERROR: no stock sysroot with alien headers at $REAL"; exit 1; }
AMIX_SYSROOT="$REAL" m68k-cbm-sysv4-gcc $CF $DEFS -I"$REAL/usr/sys/amiga/alien" -I"$SRCDIR" \
	-c "$SRCDIR/a4091-wr.c" -o "$STOCKOBJ"
NDIFF=$(LC_ALL=C m68k-linux-gnu-objdump -dr "$OBJ" | tail -n +4 > "$HERE/build/a4091_040.dis"; \
	LC_ALL=C m68k-linux-gnu-objdump -dr "$STOCKOBJ" | tail -n +4 | diff - "$HERE/build/a4091_040.dis" | grep -c '^[<>]' || true)
if [ "$NDIFF" = 0 ]; then
	echo "      differential: identical to the stock-header compile (no page geometry in the 040 arm)"
else
	echo "      differential: $NDIFF disassembly lines differ from the stock-header compile -- read them"
fi

echo "[*] T-9 gates G1/G2"
run_step all python3 "$HERE/tools/spl-gate.py" --object "$OBJ" --source "$SRCDIR/a4091-wr.c" \
	--cflags "$CF" -- $DEFS -I"$ALIEN" -I"$SRCDIR"
echo "[*] 53C710 register access widths (the a4091 lane's gate, from the same revision)"
run_step indent python3 "$SRCDIR/a4091-widths.py" "$OBJ"

echo "[*] 68060 instruction census (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" > "$HERE/build/a4091_040.lst"
run_step all python3 "$HERE/test-tools/scan060.py" "$HERE/build/a4091_040.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/a4091_040.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 100 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of a4091_040.lst -- not a listing it understood"; exit 1; }
echo "$SCAN" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: a4091_040.o is not CLEAN"; exit 1; }

echo "[*] the driver's imports must be exactly these (with -DA4091_D42, plus the D42 service):"
WANT="bprobe dev_kvmap dev_kvunmap printf sdcardbase"
case " $A4091_OPTS " in
*" -DA4091_D42 "*)
	for s in dma_prepare dma_complete; do
		echo "$NM_IN" | grep -qE " T $s\$" \
			|| { echo "[FAIL] -DA4091_D42 needs a base that exports $s (src/dma_cache040.s)"; exit 1; }
	done
	WANT="bprobe dev_kvmap dev_kvunmap dma_complete dma_prepare printf sdcardbase"
	echo "      (-DA4091_D42: the base's dma_prepare/dma_complete replace the driver's stubs)" ;;
esac
GOT=$(m68k-linux-gnu-nm "$OBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
echo "      $GOT"
for s in a4091queue a4091_bytewrite_probe a4091_dma_off a4091_kstat; do
	m68k-linux-gnu-nm "$OBJ" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s not defined by a4091_040.o"; exit 1; }
done
echo "      defines a4091queue, and a4091_bytewrite_probe / a4091_dma_off / a4091_kstat in .data"
# COMMON symbols are merged silently with a same-named kernel object by ld -r, so every name the
# driver defines or leaves COMMON must be new to the base.
m68k-linux-gnu-nm "$OBJ" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort > "$HERE/build/a4091_040.defs"
echo "$NM_IN" | awk 'NF==3{print $3}' | LC_ALL=C sort -u > "$HERE/build/a4091-base.names"
DUP=$(LC_ALL=C comm -12 "$HERE/build/a4091_040.defs" "$HERE/build/a4091-base.names")
[ -z "$DUP" ] || { echo "[FAIL] a4091_040.o defines names the base already has:"; echo "$DUP" | sed 's/^/      /'; exit 1; }
echo "      $(wc -l < "$HERE/build/a4091_040.defs") defined/COMMON names, none already in the base"

# ---------------------------------------------------------------- 4. sd's side
echo "[*] sd: the controller table and sdcardbase()"
run_step all python3 "$HERE/src/a4091_sd_rows.py" gen "$IN" "$HERE/build/a4091_scsicard.s" "$HERE/build/a4091_scsicard.syms"
OLDTABLE=$(m68k-linux-gnu-readelf -rW "$IN" | awk '/^Relocation section '"'"'\.rela\.text'"'"' /{t=1;next} /^Relocation section/{t=0} t && $1=="0000d74c" {print $5}')
[ -n "$OLDTABLE" ] || { echo "[FAIL] no relocation at .text+0xd74c in $IN"; exit 1; }
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/build/a4091_scsicard.s" -o "$HERE/build/a4091_scsicard.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/sdcardbase040.s" -o "$HERE/build/sdcardbase040.o"
[ -z "$DEVKV" ] || m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/devkvmap040.s" -o "$DEVKV"
for s in sd_queue_tbl a4091_scsicard; do
	echo "$NM_IN" | awk 'NF==3{print $3}' | grep -qx "$s" && { echo "[FAIL] $s already exists in $IN"; exit 1; }
done

# ---------------------------------------------------------------- 5. the link
STAGE="$HERE/build/unix-stage-a4091"
cp "$IN" "$STAGE"
m68k-linux-gnu-objcopy $(cat "$HERE/build/a4091_scsicard.syms") "$STAGE"
echo "[*] ld -r: base + a4091_040.o${DEVKV:+ + devkvmap040.o} + a4091_scsicard.o + sdcardbase040.o (LAST: .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$OBJ" $DEVKV "$HERE/build/a4091_scsicard.o" "$HERE/build/sdcardbase040.o"

NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in a4091queue sdcardbase a4091_scsicard dev_kvmap dev_kvunmap; do
	echo "$NM_OUT" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s is not a global definition in $OUT"; exit 1; }
done
Q=$(echo "$NM_OUT" | awk '$3=="sd_queue_tbl"{print $1}')
QS=$(echo "$NM_IN" | awk '$3=="queue" && $2=="b"{print $1}')
[ -n "$Q" ] && [ "$QS" = "$Q" ] || { echo "[FAIL] sd_queue_tbl @0x$Q is not sd's static queue[] (@0x$QS)"; exit 1; }
echo "      sdcardbase -> sd_queue_tbl @.bss 0x$Q (sd.o's controller array)"
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"

# ---------------------------------------------------------------- 6. the two sd edits
echo "[*] sd's init(): table $OLDTABLE -> a4091_scsicard, and its loop bound"
run_step all python3 "$HERE/src/a4091_sd_rows.py" patch "$OUT" "$OLDTABLE"
echo "[*] the result's root-storage family (a4091queue must be among the rows)"
run_step indent python3 "$HERE/src/check_root_family.py" "$OUT" --require-queue a4091queue

# ---------------------------------------------------------------- 7. packaging guards
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
	|| { echo "[FAIL] .text size not 4-aligned -- is sdcardbase040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     driver: $SRCID"
echo "     next:   relink-040-fpe.sh (always the last link); the card stamps as for the family"
