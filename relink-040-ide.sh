#!/bin/sh
# relink-040-ide.sh -- link the A4000 Gayle IDE driver (amix-gayle-ide, ide.c) into a kernel of
# this line and register it with sd (2026-10-02, P-15 P2).
#
# What goes in:
#   ide_040.o          ide.c, compiled here from a pinned revision of the amix-gayle-ide repository
#                      with the T-9 kernel flags for -m68040, -DIDE_NBPP=4096 (Model-B pages) and
#                      -DIDE_CACHE=1 (the driver's own 040/060 data-cache line pushes around PIO
#                      and its check that the task file is reached cache-inhibited; kmem knob
#                      ide_cache).  The driver repository owns all of that; this pass compiles it.
#   ide_scsicard.o     a new controller table, generated from the base's: every existing row by
#                      relocation, then one row, IDE_SD_ID on idequeue (src/ide_sd_rows.py, which
#                      reuses a4091_sd_rows.py's generator).
#   ide_sd_glue040.o   ide_sd_autocon: init()'s autocon call answers IDE_SD_ID through
#                      idepresent() and every other id through autocon.  The glue's header has the
#                      order rule: by default IDE ranks after every board the base registers
#                      ("Z3660 stays card 0, IDE next"); IDE_ORDER=address ranks it by its real
#                      base instead (card 0).  The owner's decision on the rule is pending.
# and three edits after the link (src/ide_sd_rows.py patch): the `lea <table>,%a3` relocation at
# .text+0xd74c, init()'s loop bound at .text+0xd79f, and init()'s `jsr autocon` at .text+0xd78e.
#
# Interrupts: none.  On this line int2_tbl is a fixed table (src/patch_a3091_intr.py), ide.c
# looks for itself there, does not find itself and runs polled -- the owner's Q5 answer.
#
# A post-pass, after any pass that replaces sd's table by name (relink-040-z3660.sh needs the
# stock `scsicard`), before relink-040-fpe.sh (always the last link).  The a4091 pass and this one
# each generate their table from whatever the base has, so both orders link -- but run this one
# AFTER the a4091 pass: insert() keeps the first two boards it is offered and drops later ones, so
# a row's position decides who loses when three answer, and the IDE row belongs last.
#
# usage: sh relink-040-ide.sh [base-kernel] [output]
#   IDE_REPO=<dir>     the amix-gayle-ide checkout (default: ../amix-gayle-ide beside this repository)
#   IDE_REV=<rev>      take ide.c from that revision.  Default: the pin below; IDE_REV= (empty)
#                      takes the checkout's working tree instead
#   IDE_ORDER=after|address   the card-order rule (default after; see src/ide_sd_glue040.s)
#   IDE_BASE_SHA256=<hex>     refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-ide}"
REPO="${IDE_REPO:-$HERE/../amix-gayle-ide}"
ORDER="${IDE_ORDER:-after}"
case "$ORDER" in after|address) ;; *) echo "ERROR: IDE_ORDER must be after or address"; exit 1 ;; esac
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$IDE_BASE_SHA256" ] || [ "$IDE_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $IDE_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] (idequeue|ide_sd_autocon)\$" \
	&& { echo "[FAIL] base already has idequeue or ide_sd_autocon -- use a base without this pass"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }
for s in autocon printf timeout; do
	echo "$NM_IN" | grep -qE " T $s\$" || { echo "[FAIL] $s is not a global T in $IN"; exit 1; }
done
echo "$NM_IN" | grep -qE " D int2_tbl\$" || { echo "[FAIL] int2_tbl is not a global D in $IN"; exit 1; }
echo "[*] the base's root-storage family"
run_step indent python3 "$HERE/src/check_root_family.py" "$IN"

# ---------------------------------------------------------------- 1. the header set
echo "[*] Model-B header set (mirror sysroot + geometry probe)"
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'
AMIX_SYSROOT="$HERE/build/sysroot-modelb"
export AMIX_SYSROOT
ALIEN="$AMIX_SYSROOT/usr/sys/amiga/alien"
[ -f "$ALIEN/sd.h" ] && [ -f "$ALIEN/rico.h" ] || { echo "ERROR: sd.h/rico.h not under $ALIEN"; exit 1; }

# ---------------------------------------------------------------- 2. the driver source
SRCDIR="$HERE/build/ide-src"
rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
# Pinned (P2, 2026-10-02): amix-gayle-ide d19812b (G1) -- the 040/060 build: IDE_NBPP, IDE_CACHE
# (cpushl/cinvl around PIO, the DTTn cache-inhibit check, ide_cache knob), polled-only on this line,
# spin budgets x4 with the ide_spins_hw high-water, and the MB banner without a >>11.  ide.c includes
# nothing from its own repository; rico.h and sd.h come from the sysroot's amiga/alien.
# Moved 2026-10-02 to 70e768e (reviewed, gayle-ide tag e2c7122): ATAPI CD-ROM via PACKET
# passthrough, slave mode 2.
IDE_REV="${IDE_REV-70e768e}"
if [ -n "$IDE_REV" ]; then
	git -C "$REPO" cat-file -e "$IDE_REV:src/ide.c" || { echo "ERROR: src/ide.c does not exist at $IDE_REV in $REPO"; exit 1; }
	git -C "$REPO" show "$IDE_REV:src/ide.c" > "$SRCDIR/ide.c"
	SRCID="$(git -C "$REPO" rev-parse "$IDE_REV") ($IDE_REV, from the repository)"
else
	echo "[*] IDE_REV empty: taking the working tree of $REPO (not pinned)"
	cp "$REPO/src/ide.c" "$SRCDIR/"
	SRCID="working tree $REPO"
	HEADREV=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)
	if [ -n "$HEADREV" ]; then
		MOD=$(git -C "$REPO" status --porcelain -- src/ide.c 2>/dev/null || true)
		SRCID="$SRCID @ $HEADREV"
		[ -z "$MOD" ] || SRCID="$SRCID (MODIFIED)"
	fi
fi
echo "[*] driver source: $SRCID"
sha256sum "$SRCDIR/ide.c" | sed 's/^/      /'

# ---------------------------------------------------------------- 3. the compile and its gates
DEFS="-DIDE_NBPP=4096 -DIDE_CACHE=1 -D__STDC__=0"
echo "[*] cross-compiling ide.c $DEFS (-m68040 dialect, Model-B headers)"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
OBJ="$HERE/build/ide_040.o"
m68k-cbm-sysv4-gcc $CF $DEFS -I"$ALIEN" -c "$SRCDIR/ide.c" -o "$OBJ"
m68k-linux-gnu-size "$OBJ" | sed 's/^/      /'
sha256sum "$OBJ" | sed 's/^/      /'
M=$(m68k-linux-gnu-readelf -SW "$OBJ" | awk '{gsub(/[][]/,"")} $2 ~ /^\.rodata/ {print $2}')
[ -z "$M" ] || { echo "[FAIL] ide_040.o carries $M -- the image has .text and .data only"; exit 1; }

echo "[*] page geometry: the compiled bytes"
run_step indent sh "$HERE/src/check_page_geometry.sh" "$OBJ"

echo "[*] T-9 gates G1/G2"
run_step all python3 "$HERE/tools/spl-gate.py" --object "$OBJ" --source "$SRCDIR/ide.c" \
	--cflags "$CF" -- $DEFS -I"$ALIEN"

echo "[*] 68060 instruction census (kernel mode: nothing emulates a hit)"
# ide.c's idequeue dispatches on the SCSI opcode through a gcc switch table, whose 16-bit offsets
# objdump decodes as code: at d19812b one of them prints as MOVEP.  tools/scan060-tables.py accepts
# a MOVEP only inside a dispatch table it finds in the same listing, and refuses everything else.
LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" > "$HERE/build/ide_040.lst"
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/ide_040.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 100 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of ide_040.lst -- not a listing it understood"; exit 1; }
run_step indent python3 "$HERE/tools/scan060-tables.py" "$HERE/build/ide_040.lst"

echo "[*] the driver's imports must be exactly these:"
WANT="int2_tbl printf timeout"
GOT=$(m68k-linux-gnu-nm "$OBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
echo "      $GOT"
for s in idequeue idepresent; do
	m68k-linux-gnu-nm "$OBJ" | grep -qE " T $s\$" || { echo "[FAIL] $s not defined by ide_040.o"; exit 1; }
done
m68k-linux-gnu-nm "$OBJ" | grep -qE " [DBC] ide_cache\$" || { echo "[FAIL] ide_040.o has no ide_cache knob -- not an IDE_CACHE build"; exit 1; }
echo "      defines idequeue, idepresent, and the ide_cache knob"
m68k-linux-gnu-nm "$OBJ" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort > "$HERE/build/ide_040.defs"
echo "$NM_IN" | awk 'NF==3{print $3}' | LC_ALL=C sort -u > "$HERE/build/ide-base.names"
DUP=$(LC_ALL=C comm -12 "$HERE/build/ide_040.defs" "$HERE/build/ide-base.names")
[ -z "$DUP" ] || { echo "[FAIL] ide_040.o defines names the base already has:"; echo "$DUP" | sed 's/^/      /'; exit 1; }
echo "      $(wc -l < "$HERE/build/ide_040.defs") defined/COMMON names, none already in the base"

# ---------------------------------------------------------------- 4. sd's side
echo "[*] sd: the controller table, and the glue"
run_step all python3 "$HERE/src/ide_sd_rows.py" gen "$IN" "$HERE/build/ide_scsicard.s" "$HERE/build/ide_scsicard.syms"
OLDTABLE=$(sed -n 's/^| Rows 0-[0-9]* reproduce \([^ ]*\) by relocation.*/\1/p' "$HERE/build/ide_scsicard.s")
[ -n "$OLDTABLE" ] || { echo "[FAIL] could not read the base's table name from ide_scsicard.s"; exit 1; }
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/build/ide_scsicard.s" -o "$HERE/build/ide_scsicard.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/ide_sd_glue040.s" -o "$HERE/build/ide_sd_glue040.o"
GOT=$(m68k-linux-gnu-nm "$HERE/build/ide_sd_glue040.o" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "autocon idepresent" ] || { echo "[FAIL] the glue's imports are: $GOT"; exit 1; }
for o in ide_scsicard ide_sd_glue040; do
	LC_ALL=C m68k-linux-gnu-objdump -d "$HERE/build/$o.o" > "$HERE/build/$o.lst"
	python3 "$HERE/test-tools/scan060.py" "$HERE/build/$o.lst" | grep -q 'CLEAN -- no candidate found' \
		|| { echo "[FAIL] scan060: $o.o is not CLEAN"; exit 1; }
done
echo "      ide_scsicard.o and ide_sd_glue040.o: scan060 CLEAN; glue imports autocon idepresent"

# ---------------------------------------------------------------- 5. the link
STAGE="$HERE/build/unix-stage-ide"
cp "$IN" "$STAGE"
SYMS=$(cat "$HERE/build/ide_scsicard.syms")
[ -z "$SYMS" ] || m68k-linux-gnu-objcopy $SYMS "$STAGE"
echo "[*] ld -r: base + ide_040.o + ide_scsicard.o + ide_sd_glue040.o (LAST: .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$OBJ" "$HERE/build/ide_scsicard.o" "$HERE/build/ide_sd_glue040.o"
NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in idequeue idepresent ide_sd_autocon; do
	echo "$NM_OUT" | grep -qE " T $s\$" || { echo "[FAIL] $s is not a global T in $OUT"; exit 1; }
done
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] linked, no unresolved symbols"

# ---------------------------------------------------------------- 6. sd's three edits
echo "[*] sd's init(): table $OLDTABLE -> ide_scsicard, its loop bound, its autocon call (order: $ORDER)"
run_step all python3 "$HERE/src/ide_sd_rows.py" patch "$OUT" "$OLDTABLE" --order "$ORDER"
echo "[*] the result's root-storage family (idequeue must be among the rows)"
run_step indent python3 "$HERE/src/check_root_family.py" "$OUT"
python3 "$HERE/src/check_root_family.py" "$OUT" | grep -q idequeue \
	|| { echo "[FAIL] check_root_family does not list idequeue among the rows"; exit 1; }

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
	|| { echo "[FAIL] .text size not 4-aligned -- is ide_sd_glue040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT  (IDE order: $ORDER)"
echo "     next: relink-040-fpe.sh (always the last link)"
