#!/bin/sh
# relink-040-cdfs.sh -- link amix-cdfs's read-only CD filesystem into a kernel of this line, in
# RFS's vfssw row (2026-10-02, PO-02; decisions D43/D44).
#
# What goes in:
#   libcdfskern.o      amix-cdfs's relocatable kernel object, taken as delivered and pinned by md5
#                      (CDFS_MD5).  D43: it must carry no kernel-mode 64-bit multiply or divide,
#                      because the 060 traps them and this line's ISP has no supervisor arm; the
#                      census below is the gate.  Its .rodata is folded into .data
#                      (tools/fold-rodata.sh, the same fold the FPE pass uses).
#   _lshrdi3.o _udivdi3.o _umoddi3.o
#                      the three libgcc helpers it imports, taken from the cross toolchain's own
#                      libgcc.a (the base kernel has none of them); each must scan CLEAN.
#   cdfs_glue040.o     the row's name "cdfs", and cdfs_rfsys, the guard that keeps RFS's system
#                      call from walking tables that are no longer allocated (src/cdfs_glue040.s).
# and three edits after the link (src/patch_cdfs_vfssw.py): vfssw[4]'s name and init, and
# sysent[78].  That script asserts the PO-02 proof first -- nothing reaches vfssw row 4 except the
# table walks -- and KNOWN-ISSUES DRIVER-LINE-3 records it.
#
# PAGE GEOMETRY.  The object is compiled against the stock headers (NBPP 2048), and the page gate
# finds seven shifts by 11.  All seven are 2048-byte CD-sector arithmetic in the ISO 9660, Joliet
# and UDF readers and in cdfs_bytes_to_dev_blocks, not page numbers; the only page constant cdfs
# uses is NBPP as its DMA bound (no transfer crosses a 2 KiB boundary), which a 4 KiB page can only
# satisfy more easily.  So the gate here is site-exact: the shifts must be in exactly those seven
# functions, and a shift by 11 anywhere else fails the build.
#
# A post-pass, before relink-040-fpe.sh (always the last link).  It touches only vfssw, sysent and
# its own objects, so its place among the dd, a3091q, z3660, monsw, zz9000, a4091 and ide passes is
# free.  kerntools names the family (KD060-Z-CD: KD060-Z's chain plus this pass).
#
# usage: sh relink-040-cdfs.sh [base-kernel] [output]
#   CDFS_OBJ=<file>    the object (default: ../amix-cdfs/build/cd06-new/libcdfskern.o)
#   CDFS_MD5=<hex>     its pinned md5 (default below); CDFS_MD5= (empty) takes any, and says so
#   CDFS_BASE_SHA256=<hex>   refuse any base but that one
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"
. "$HERE/tools/fold-rodata.sh"

IN="${1:-$HERE/build/unix-040}"
OUT="${2:-$HERE/build/unix-040-cdfs}"
OBJSRC="${CDFS_OBJ:-$HERE/../amix-cdfs/build/cd06-new/libcdfskern.o}"
# Pinned (PO-02, 2026-10-02): amix-cdfs b383d14 (CD-06, "Avoid 32x32->64 multiplies in the AMIX
# kernel object"): scan060 0 candidates, imports unchanged from the 030 object.
CDFS_MD5="${CDFS_MD5-839553311ffa92b0b0b607988581a184}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
[ -f "$OBJSRC" ] || { echo "ERROR: cdfs object missing: $OBJSRC"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$CDFS_BASE_SHA256" ] || [ "$CDFS_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $CDFS_BASE_SHA256"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] (cdfsinit|cdfs_rfsys)\$" \
	&& { echo "[FAIL] base already has cdfsinit or cdfs_rfsys -- use a base without this pass"; exit 1; }
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }
STAGE="$HERE/build/unix-stage-cdfs"
cp "$IN" "$STAGE"

# ---------------------------------------------------------------- 1. the object
OBJ="$HERE/build/libcdfskern.o"
cp "$OBJSRC" "$OBJ"
MD5=$(md5sum "$OBJ" | cut -d' ' -f1)
echo "[*] cdfs object: $OBJSRC  (md5 $MD5)"
if [ -n "$CDFS_MD5" ]; then
	[ "$MD5" = "$CDFS_MD5" ] || { echo "[FAIL] md5 $MD5 is not the pinned $CDFS_MD5"; exit 1; }
else
	echo "      CDFS_MD5 empty: NOT pinned"
fi
m68k-linux-gnu-size "$OBJ" | sed 's/^/      /'
echo "[*] the object's imports must be exactly these:"
WANT="__lshrdi3 __udivdi3 __umoddi3 bcopy cmn_err copyinstr fs_cmp fs_frlock fs_nosys fs_pathconf fs_poll fs_rwlock fs_rwunlock fs_setfl getudev kmem_alloc kmem_free kmem_zalloc memcpy nfstype sdopen sdqueue sleep strcmp strlen strncpy suser uiomove vfs_devsearch vfssw vn_rele vtop wakeup"
GOT=$(m68k-linux-gnu-nm "$OBJ" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
echo "      $(echo "$GOT" | wc -w) names"
for s in cdfsinit cdfs_vfsops; do
	m68k-linux-gnu-nm "$OBJ" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s not defined by the object"; exit 1; }
done
# Globals the object defines must be new to the base's globals.  memcmp is also a file-static in
# the base: the two never meet, because a local resolves inside its own object.
m68k-linux-gnu-nm "$OBJ" | awk '$2 ~ /^[TDBC]$/{print $3}' | LC_ALL=C sort > "$HERE/build/cdfs.defs"
echo "$NM_IN" | awk 'NF==3 && $2 ~ /^[TDBCA]$/{print $3}' | LC_ALL=C sort -u > "$HERE/build/cdfs-base.globals"
DUP=$(LC_ALL=C comm -12 "$HERE/build/cdfs.defs" "$HERE/build/cdfs-base.globals")
[ -z "$DUP" ] || { echo "[FAIL] the object defines globals the base already has:"; echo "$DUP" | sed 's/^/      /'; exit 1; }
echo "      $(wc -l < "$HERE/build/cdfs.defs") defined names, none a global of the base"

echo "[*] fold the object's .rodata into .data"
fold_rodata "$OBJ"

echo "[*] page geometry: shifts by 11 only in the seven CD-sector functions"
SITES=$(LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" | awk '/^[0-9a-f]+ <.*>:$/{fn=$2} /moveq #11,/{getline nx; if (nx ~ /lsrl|asrl/) print fn}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
SECTORFNS="<cdfs_bytes_to_dev_blocks>: <iso_readdir>: <iso_readlink>: <joliet_readdir>: <odfs_iso_merge_multi_extent>: <udf_mount>: <udf_read_bytes>:"
[ "$SITES" = "$SECTORFNS" ] \
	|| { echo "[FAIL] shift-by-11 sites are in: $SITES"; echo "       expected exactly:          $SECTORFNS"; exit 1; }
echo "      7 sites, all 2048-byte sector arithmetic: $(echo "$SITES" | tr -d '<>:')"

echo "[*] 68060 instruction census (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$OBJ" > "$HERE/build/libcdfskern.lst"
run_step indent python3 "$HERE/tools/scan060-tables.py" "$HERE/build/libcdfskern.lst"

# ---------------------------------------------------------------- 2. libgcc's three helpers
LIBGCC="${AMIX_CROSS:-$(dirname "$(dirname "$(command -v m68k-cbm-sysv4-gcc)")")}/lib/gcc-lib/m68k-cbm-sysv4/2.7.2.3/libgcc.a"
[ -f "$LIBGCC" ] || { echo "ERROR: libgcc.a not found at $LIBGCC"; exit 1; }
echo "[*] libgcc helpers from $LIBGCC"
LGDIR="$HERE/build/cdfs-libgcc"
rm -rf "$LGDIR"; mkdir -p "$LGDIR"
(cd "$LGDIR" && m68k-linux-gnu-ar x "$LIBGCC" _lshrdi3.o _udivdi3.o _umoddi3.o)
LGOBJS=
for o in _lshrdi3 _udivdi3 _umoddi3; do
	f="$LGDIR/$o.o"
	[ -z "$(m68k-linux-gnu-nm "$f" | awk '$1=="U"')" ] || { echo "[FAIL] $o.o has imports"; exit 1; }
	LC_ALL=C m68k-linux-gnu-objdump -d "$f" > "$LGDIR/$o.lst"
	python3 "$HERE/test-tools/scan060.py" "$LGDIR/$o.lst" | grep -q 'CLEAN -- no candidate found' \
		|| { echo "[FAIL] scan060: $o.o is not CLEAN"; exit 1; }
	echo "      $o.o  md5 $(md5sum "$f" | cut -c1-8)  no imports, scan060 CLEAN"
	fold_rodata "$f"		# the division helpers carry a 256-byte bit-count table
	LGOBJS="$LGOBJS $f"
done

# ---------------------------------------------------------------- 3. the glue
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/cdfs_glue040.s" -o "$HERE/build/cdfs_glue040.o"
GOT=$(m68k-linux-gnu-nm "$HERE/build/cdfs_glue040.o" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "rfsys sndd" ] || { echo "[FAIL] the glue's imports are: $GOT"; exit 1; }
LC_ALL=C m68k-linux-gnu-objdump -d "$HERE/build/cdfs_glue040.o" > "$HERE/build/cdfs_glue040.lst"
python3 "$HERE/test-tools/scan060.py" "$HERE/build/cdfs_glue040.lst" | grep -q 'CLEAN -- no candidate found' \
	|| { echo "[FAIL] scan060: cdfs_glue040.o is not CLEAN"; exit 1; }
echo "      cdfs_glue040.o: imports rfsys sndd, scan060 CLEAN"

# ---------------------------------------------------------------- 4. the link
echo "[*] ld -r: base + libcdfskern.o + libgcc x3 + cdfs_glue040.o (LAST: .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$OBJ" $LGOBJS "$HERE/build/cdfs_glue040.o"
NM_OUT=$(m68k-linux-gnu-nm "$OUT")
for s in cdfsinit cdfs_rfsys cdfs_vsw_name __udivdi3; do
	echo "$NM_OUT" | grep -qE " [TD] $s\$" || { echo "[FAIL] $s is not a global in $OUT"; exit 1; }
done
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
! m68k-linux-gnu-readelf -SW "$OUT" | grep -q '\.rodata' || { echo "[FAIL] $OUT carries .rodata"; exit 1; }
echo "[OK] linked, no unresolved symbols, no .rodata"

# ---------------------------------------------------------------- 5. the row, the guard, the proof
echo "[*] vfssw[4] -> cdfs, sysent[78] -> cdfs_rfsys (the proof is asserted first)"
run_step all python3 "$HERE/src/patch_cdfs_vfssw.py" "$OUT"
echo "[*] the result's root-storage family (unchanged: cdfs never mounts root)"
run_step indent python3 "$HERE/src/check_root_family.py" "$OUT"

# ---------------------------------------------------------------- 6. packaging guards
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
	|| { echo "[FAIL] .text size not 4-aligned -- is cdfs_glue040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     next: relink-040-fpe.sh (always the last link)"
