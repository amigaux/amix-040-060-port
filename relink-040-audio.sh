#!/bin/sh
# relink-040-audio.sh -- the stock audio driver (/dev/audio, c 46) rebuilt with the /dev/paula
# exclusion, for a module kernel of kabi minor 3 (amix-dlm contract C3-2 version 2, section 3).
#
# The Paula module (amix-paula, /dev/paula on c 54) imports two data names the stock kernel does
# not have.  The audio driver defines them once patched:
#   paula_busy    set by the module's open; /dev/audio's open then fails with EBUSY
#   audio_nopen   /dev/audio's clients; the module's open fails with EBUSY while it is not zero
# A kernel claims minor 3 only with this pass in its chain: relink-040-dlm.sh refuses the claim
# without the two names, and so do the symbol gate and the fingerprint.
#
# The amix-paula repository is a SEPARATE PROJECT and is never modified.  Its three source patchers
# are taken at PAULA_REV with git show, so its working tree does not matter, and are applied to a
# build-time copy of the stock driver ($AMIX_SYS/amiga/driver/audio.c and audio.h), in this order:
#   port/src/patch_audio_safeclose.py   /dev/audio stops the channels a client holds before it
#                                       frees the client (a stock use-after-free on a killed player)
#   port/src/patch_audio_initwait.py    audioinit()'s wait for each channel's hand-fed word is
#                                       bounded (about 2 ms); a silent Paula fails the open EIO
#                                       instead of holding the box at splaudio for good
#   port/src/patch_audio_paula.py       the two names, and both opens test the other's flag with no
#                                       sleep between test and set
# Each patcher finds its places by the SHA-256 of the stock lines and refuses any other audio.c.
# Commodore's source is not in this repository.  The compile and the link are those of amix-paula's
# port/relink-040-audio-paula.sh at the same revision: the output is byte-identical to that script's
# run with AUDIO_SRC = the stock driver already patched with the safe close and the bounded wait.
#
# The rebuilt object is linked after the base, whose audioinfo, audioinit and audiointr are
# weakened: cdevsw and the level-4 interrupt bind to the new driver, the stock one stays as dead code.
#
# Order (the module kernel): ... -> f6 -> audio -> rth1 (DLM=1) -> kinfo (DLM=1) -> dlm -> fpe.
# It runs before rth1 because rth1 and kinfo leave dlm_kinfo_list and dlm_marc_post open for the
# dlm pass, and this pass refuses a base with anything unresolved.
#
# usage: sh relink-040-audio.sh [base-kernel] [output]
#   PAULA_REPO=<dir>   amix-paula (default: the sibling checkout ../amix-paula)
#   PAULA_REV=<rev>    the amix-paula revision the patchers come from (default: the pin below)
#   AMIX_SYS=<dir>     the stock kernel source tree (usr/sys) the driver is copied from.  Default:
#                      $AMIX_ROOT/usr/sys when the installation has it, else the cross toolchain's
#                      copy, $AMIX_CROSS/m68k-cbm-sysv4/sysroot/usr/sys, which gcc-cross-amix makes
#                      from the same installation
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

# 62fdcab: the open race closed on both sides (patch_audio_paula.py re-tests paula_busy at splaudio
# after its KM_SLEEP allocation, five fingerprinted places), the safe close, and the bounded
# audioinit() wait (patch_audio_initwait.py, three fingerprinted places).
PAULA_REPO="${PAULA_REPO:-$HERE/../amix-paula}"
PAULA_REV="${PAULA_REV:-62fdcab}"
if [ -z "$AMIX_SYS" ]; then
	if [ -f "$AMIX_ROOT/usr/sys/amiga/driver/audio.c" ]; then AMIX_SYS="$AMIX_ROOT/usr/sys"
	else AMIX_SYS="$AMIX_CROSS/m68k-cbm-sysv4/sysroot/usr/sys"; fi
fi
SRC="$AMIX_SYS/amiga/driver"
for f in "$SRC/audio.c" "$SRC/audio.h" "$AMIX_SYS/amiga/inc/memory.h"; do
	[ -f "$f" ] || { echo "ERROR: $f missing (set AMIX_SYS to the stock usr/sys)"; exit 1; }
done

IN="${1:-$HERE/build/unix-040-f6}"
OUT="${2:-$HERE/build/unix-040-audio}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
echo "[*] base: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"
NM=m68k-linux-gnu-nm
GLOBALS="audioinfo audioinit audiointr"
for s in $GLOBALS; do
	[ "$($NM "$IN" | grep -cE " [TD] $s\$")" -eq 1 ] || { echo "[FAIL] base: $s not a unique global"; exit 1; }
done
$NM "$IN" | grep -qE " [Ww] audioinfo$" && { echo "[FAIL] base already has a relinked audio driver"; exit 1; }
for s in paula_busy audio_nopen; do
	$NM "$IN" | grep -qE " [A-Za-z] $s\$" && { echo "[FAIL] base already defines $s"; exit 1; }
done

# ---------------------------------------------------------------- 1. the patchers at PAULA_REV
REV=$(git -C "$PAULA_REPO" rev-parse --verify "$PAULA_REV^{commit}") \
	|| { echo "ERROR: $PAULA_REV is not a commit in $PAULA_REPO"; exit 1; }
P="$HERE/build/paula-rev"; rm -rf "$P"; mkdir -p "$P"
for f in patch_audio_safeclose.py patch_audio_initwait.py patch_audio_paula.py; do
	git -C "$PAULA_REPO" show "$REV:port/src/$f" > "$P/$f" \
		|| { echo "ERROR: port/src/$f does not exist at $PAULA_REV in $PAULA_REPO"; exit 1; }
done
echo "[*] amix-paula $(echo "$REV" | cut -c1-7): patch_audio_safeclose.py, patch_audio_initwait.py, patch_audio_paula.py"
echo "      stock driver: $SRC (audio.c sha256 $(sha256sum "$SRC/audio.c" | cut -c1-16))"

# ---------------------------------------------------------------- 2. the driver
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'
AMIX_SYSROOT="$HERE/build/sysroot-modelb"; export AMIX_SYSROOT
B="$HERE/build/audiosrc"; rm -rf "$B"; mkdir -p "$B"
cp "$SRC/audio.c" "$SRC/audio.h" "$B/"
# the Amiga memory.h, not libc's <memory.h> that the -I order would find first
cp "$AMIX_SYS/amiga/inc/memory.h" "$B/"
run_step 1 python3 "$P/patch_audio_safeclose.py" "$B/audio.c"
run_step 1 python3 "$P/patch_audio_initwait.py" "$B/audio.c"
run_step 1 python3 "$P/patch_audio_paula.py" "$B/audio.c"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
# -traditional knows no "signed"; audio.h and audiohw.h use "signed char"
CF="$CF -Dsigned=__signed__"
echo "[*] cross-compiling audio.c"
(cd "$B" && m68k-cbm-sysv4-gcc $CF -I. -I"$AMIX_SYS/amiga/inc" -c audio.c -o "$HERE/build/audio_040.o")
# -traditional puts the driver's strings in .data; the kernel's .data must stay a 4-byte multiple
# (the loader puts .bss right after it), so a byte-aligned filler object tops it up
ODS=$(( 0x$(m68k-linux-gnu-readelf -SW "$HERE/build/audio_040.o" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
printf '\t.data\n\t.space %d\n' $(( (4 - ODS % 4) % 4 )) > "$HERE/build/audio_pad.s"
m68k-cbm-sysv4-gcc -c "$HERE/build/audio_pad.s" -o "$HERE/build/audio_pad.o"
m68k-linux-gnu-objcopy --set-section-alignment .data=1 "$HERE/build/audio_pad.o"
for s in paula_busy audio_nopen; do
	$NM "$HERE/build/audio_040.o" | grep -qE " [DdBbC] $s\$" || { echo "[FAIL] audio_040.o does not define $s"; exit 1; }
done
echo "[*] 68060 instruction census of the rebuilt driver"
run_step indent m68k-cbm-sysv4-scan060 "$HERE/build/audio_040.o"
run_step indent sh "$HERE/src/check_page_geometry.sh" "$HERE/build/audio_040.o"
if m68k-linux-gnu-objdump -d "$HERE/build/audio_040.o" | grep -E "(mul|div)[su]l[.a-z]*\s+[^,]*,%d[0-7]:%d[0-7]"; then
	echo "[FAIL] audio_040.o has 64-bit mul/div forms (060 vector 61)"; exit 1; fi
SR=$(m68k-linux-gnu-objdump -d "$HERE/build/audio_040.o" | grep -cE ',%sr$')
[ "$SR" -gt 0 ] || { echo "[FAIL] audio_040.o writes %sr nowhere: spl()/splx() lost"; exit 1; }
echo "[OK] no 64-bit mul/div forms; $SR SR writes (spl/splx present)"

# ---------------------------------------------------------------- 3. the link
STAGE="$HERE/build/unix-stage-audio"; cp "$IN" "$STAGE"
W=""; for s in $GLOBALS; do W="$W --weaken-symbol $s"; done
m68k-linux-gnu-objcopy $W "$STAGE"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$HERE/build/audio_040.o" "$HERE/build/audio_pad.o"
for s in $GLOBALS; do
	[ "$($NM "$OUT" | grep -cE " [TD] $s\$")" -eq 1 ] || { echo "[FAIL] $s: not exactly one strong definition"; exit 1; }
done
LEAK=$($NM "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved:"; echo "$LEAK"; exit 1; }
WEAK=$($NM "$OUT" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] weak symbols survive the link: $WEAK"; exit 1; }
echo "[OK] audioinfo, audioinit, audiointr bound to the rebuilt driver; none unresolved, none weak"
echo "      $($NM "$OUT" | awk '$3=="paula_busy" || $3=="audio_nopen" {printf "%s %s %s  ", $3, $2, $1}')"
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".text"{to=$5;ts=$6} $2==".data"{do_=$5} END{print to, ts, do_}')
set -- $CONTIG; set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." || { echo "[FAIL] text/data NOT contiguous"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." || { echo "[FAIL] .data misaligned"; exit 1; }
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"
echo "[OK] built $OUT"
