#!/bin/sh
# relink-040-dlm.sh -- splice amix-dlm's module core into a kernel of this line: the k46 module
# kernel (amix-dlm docs/plan/stage-3-kernel-brief.md, step 7; contracts C3-2, C3-3, C3-4).
#
#   the core       amix-dlm core/upstream with core/series applied (kdedon's MIT DLM core and
#                  our patch queue), core/plat/amiga.c + plat/k46/line.c, loader/common's
#                  sha256.c and crc32.c; taken from DLM_REV with git archive, so amix-dlm's
#                  working tree does not matter
#   ident.o        tools/mkident.py --asm: dlm_ident (AXK1) and the arena's zero block in .data
#   ksym.o         mkksym -a abi/k46/ddi.list -a abi/k46/core.list: the allowlisted symbol block
#   devkvmap040.o  dev_kvmap/dev_kvunmap (src/devkvmap040.s), unless the base has them
#   libgcc.a       __lshrdi3, __udivdi3, __umoddi3 (DDI v1), from the toolchain
#   dlm_tail040.s  the closing .balign 4
#
# The base is weakened where the core replaces the stock object (dmainit, execsw, fmodsw,
# scrcon_put, aciabintr) and keeps the stock tables and functions as __amix_*; what the splice
# adds is linked first, its .rodata folded into .data (tools/fold-rodata.sh), then linked with
# the base.  No weak symbol survives and nothing stays undefined but etext, edata and end.
#
# Order (the module kernel, one family: KD060-Z):
#   dd -> z3660 (Z3660_NET=off) -> f4arms -> f6 -> rth1 (DLM=1) -> kinfo (DLM=1) -> dlm -> fpe
# monsw and zz9000 are not linked: majors 49, 51 and 52 belong to modules.  The base must be
# kinfo's DLM=1 output: its two open imports, dlm_kinfo_list and dlm_marc_post, are the core's.
# fpe stays the last link.  `relink-040-dlm.sh --fill <kernel>` then fills the block's sizes and
# AXK1's offsets in place, takes the fingerprint (tools/mkabi.py against abi/k46/abi-<kabi>.txt,
# C3-3 section 4) and runs the gate (the brief's steps 9 and 10), on the last form whose layout
# changes: after amix-kerntools' W-D7 probe inject, which grows .text (124 bytes on KD060-Z) and so
# moves every .data image offset; before emit-family-chains, which patches .data words only.
#
# usage: sh relink-040-dlm.sh [base-kernel] [output]
#        sh relink-040-dlm.sh --fill <kernel>
#   DLM_REPO=<dir>   amix-dlm (default: the sibling checkout)
#   DLM_REV=<rev>    the amix-dlm revision the core and tools come from (default: the pin below)
#   DLM_KABI=<tag>   default k46.1.2; must equal the base's kinfo_kabi
#   DLM_ARENA=<n>    the arena's capacity (default 0x60000, M-MOD1)
#   DLM_ABI_NEW=1    --fill: a fingerprint that moved is written (KERNEL.abi.txt) and taken instead of
#                    failing -- only for the one rewrite of a tag's reference C3-3 allows
# A core that defines dlm_halt (core patch 0030) gets mdboot's haltsys and rtnfirm calls through
# src/dlm_halt040.s (src/patch_dlm_halt.py): the halt pass runs on halt and reboot, never on panic.
# A core that defines dlm_sd_close (core patch 0032, C4-1 section 3) takes sd's module registrations
# from the four-card sd's sd4_init (src/patch_dlm_call.py); it needs a relink-040-sd4card.sh base.
# A core that defines dlm_marc_root (core patch 0034, spec 30 section 3) gets rth1_mountroot's call
# before rth1_apply (rth1_nomarc, relink-040-rth1.sh DLM=1): the arena's root modules link there.
# A core that defines vfssw and nfstype (core patch 0040, C4-6 section 2) replaces them as it does
# execsw and fmodsw: the stock ones weakened and kept as __amix_vfssw / __amix_nfstype.
# A core that reads dlm_static_root (core patch 0037, C4-4 version 4) gets the base's root= list
# (tools/kabi-sidecar.py --root) in ident.o: marc_root skips a root module for a controller the
# kernel drives itself.
# The fault resolver's "DBG krnxflt FAILEXIT" console line goes behind krnx_fail_print (0 here; the
# base and static families keep it): src/krnx_quiet040.s, src/patch_krnx_quiet.py.
# From kabi k46.1.1 on, bdevsw[20] -- the stock RAM disk's block row -- is freed for the module
# ramdisk (src/patch_free_brow.py): every routine nodev, d_flag &nullflag (0).
#
#   DLM_U1=1         compile the core with -DDLM_U1 (core patch 0023's U1 probe): a measurement build
#                    only, never shipped; without it the core is unchanged
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

# 76f83d8: core patches 0001-0045 (0029 no-sleep, 0030 dlm_halt, 0031 block rows, 0032 sd_register,
# 0033 the arena load path, 0034 dlm_marc_root, 0035 match=, 0036 root_defer, 0037 dlm_static_root,
# 0038 mkmod's rank, 0039 the ramdisk image, 0040 vfs_register, 0041 moddefs block rows, 0042 the
# filesystem layouts in the fingerprint and 13 more DDI names, 0043 the rootfs promotion, 0044 block
# rows as the stock fix_swtbls leaves the switch, 0045 safe mode's safe=1 boot members) and
# abi/k46/core.list's 100 core-tier names in the symbol block (what the carved ufs imports), the arena
# 16-aligned (C3-3 version 5), kabi k46.1.2 with the five DMA names (C4-5 v4: dma_prepare and
# dma_complete are the base's src/dma_cache040.s; dma_alloc hands out heap pages through their DTT0
# alias, purged by physical line at alloc and free, and addressed only through it); abi 2ab48658;
# reviewed 2026-10-27.
# 7b07bce: plat_dmainit skips the leading blank of the stamped buildid (" 68060-..."), so the core's
# build id equals a core-tier module's build= (before it, ufs was refused: EBADVER); abi unchanged.
DLM_REPO="${DLM_REPO:-$HERE/../amix-dlm}"
DLM_REV="${DLM_REV:-7b07bce}"
DLM_KABI="${DLM_KABI:-k46.1.2}"
DLM_ARENA="${DLM_ARENA:-0x60000}"
S="$HERE/build/dlm-rev"
REV=$(git -C "$DLM_REPO" rev-parse --verify "$DLM_REV^{commit}") \
	|| { echo "ERROR: $DLM_REV is not a commit in $DLM_REPO"; exit 1; }

# the core and the kit's tools at DLM_REV, staged once per revision
stage() {
	[ -f "$S/.rev" ] && [ "$(cat "$S/.rev")" = "$REV" ] && return 0
	rm -rf "$S"; mkdir -p "$S/kit" "$S/obj"
	git -C "$DLM_REPO" archive "$REV" core abi tools loader/common tests/host/axrel.c toolchain.pin \
		| tar -x -C "$S/kit"
	cp -R "$S/kit/core/upstream" "$S/core"
	while read p; do
		case "$p" in \#*|"") continue ;; esac
		patch -p1 -s -d "$S/core" < "$S/kit/core/patches/$p" || { echo "[FAIL] core patch $p"; exit 1; }
	done < "$S/kit/core/series"
	HCC="${HOSTCC:-cc} -std=gnu89 -O -Wall -Wno-parentheses -Wno-unused-but-set-variable"
	$HCC -DDLM_TOOL -I"$S/core" -I"$S/core/include" -o "$S/mkksym" \
		"$S/core/tools/mkksym.c" "$S/core/dlm_sym.c"
	${HOSTCC:-cc} -O2 -I"$S/kit/loader/common" -o "$S/axrel" "$S/kit/tests/host/axrel.c" \
		"$S/kit/loader/common/rel.c"
	echo "$REV" > "$S/.rev"
}

# the probe's offset table (the brief's step 2), for the core and for the fingerprint
offs() {
	sh "$S/core/tools/mkoffs" m68k-cbm-sysv4-gcc $AMIX_KERNEL_CFLAGS -I"$S/core/include" > "$S/core/dlm_offs.h" \
		|| { echo "[FAIL] mkoffs"; exit 1; }
}

# ================================================================ --fill: steps 9 and 10
if [ "$1" = --fill ]; then
	K="$2"
	[ -f "$K" ] || { echo "ERROR: kernel missing: $K"; exit 1; }
	m68k-linux-gnu-nm "$K" | grep -qE " [Tt] fpe_vec11\$" \
		|| { echo "[FAIL] $K has no FPE: --fill runs on relink-040-fpe.sh's output"; exit 1; }
	stage
	offs
	echo "[*] amix-dlm $(echo "$REV" | cut -c1-7): mkksym -f, mkident.py --fill, --check, mkabi.py, ksymgate"
	run_step indent "$S/mkksym" -f "$K"
	python3 "$S/kit/tools/mkident.py" --fill "$K" > "$K.dlm" || { echo "[FAIL] mkident.py --fill"; exit 1; }
	sed 's/^/      /' "$K.dlm"
	run_step indent python3 "$S/kit/tools/mkident.py" --check "$K"
	REF="$S/kit/abi/k46/abi-$DLM_KABI.txt"
	ABI="python3 $S/kit/tools/mkabi.py"
	if $ABI --check "$REF" "$K" "$S/kit/abi/k46/ddi.list" "$S/core/dlm_offs.h" > "$K.abi" 2>&1; then
		sed 's/^/      /' "$K.abi"
	else
		sed 's/^/      /' "$K.abi"
		[ "$DLM_ABI_NEW" = 1 ] || { echo "[FAIL] mkabi.py: the fingerprint moved and the kabi tag did not"; exit 1; }
		$ABI --text "$K.abi.txt" "$K" "$S/kit/abi/k46/ddi.list" "$S/core/dlm_offs.h" > "$K.abi" \
			|| { echo "[FAIL] mkabi.py --text"; exit 1; }
		echo "      DLM_ABI_NEW=1: $(cat "$K.abi"), the text in $(basename "$K").abi.txt -- the new reference"
	fi
	python3 "$S/kit/tools/ksymgate.py" "$S/axrel" "$K" "$S/kit/abi/k46/ddi.list" "$S/kit/abi/k46/core.list" \
		> "$K.gate" 2>&1 || { sed 's/^/      /' "$K.gate"; echo "[FAIL] ksymgate"; exit 1; }
	sed 's/^/      /' "$K.gate"
	echo "[OK] filled $K: AXK1 lines in $(basename "$K").dlm, abi= in .abi, the gate in .gate"
	exit 0
fi

IN="${1:-$HERE/build/unix-040-kinfo}"
OUT="${2:-$HERE/build/unix-040-dlm}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
echo "[*] base: $(basename "$IN")  (sha256 $(sha256sum "$IN" | cut -d' ' -f1))"

# ---------------------------------------------------------------- 0. the base's shape
NM_IN=$(m68k-linux-gnu-nm "$IN")
echo "$NM_IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- not a finished relink-040.sh output"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
echo "$NM_IN" | grep -qE " [Tt] dlm_init\$" \
	&& { echo "[FAIL] base already has the module core"; exit 1; }
for s in z3660ethinfo zz9000open monswopen; do
	echo "$NM_IN" | grep -qE " [TtDd] $s\$" \
		&& { echo "[FAIL] base links $s: the module kernel's base leaves z3660eth, zz9000 and monsw out"; exit 1; }
done
for s in kinfoopen rth1_mountroot dmainit scrcon_put aciabintr; do
	echo "$NM_IN" | grep -qE " T $s\$" || { echo "[FAIL] base has no global $s"; exit 1; }
done
for s in execsw fmodsw; do
	echo "$NM_IN" | grep -qE " D $s\$" || { echo "[FAIL] base has no global .data $s"; exit 1; }
done
WEAK=$(echo "$NM_IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base"; exit 1; }
U=$(echo "$NM_IN" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$U" = "dlm_kinfo_list dlm_marc_post" ] \
	|| { echo "[FAIL] the base's open imports are '$U', not kinfo's and rth1's DLM=1 pair"; exit 1; }
run_step indent python3 "$HERE/src/check_dlm_splice.py" --free-rows 49,51,52 "$IN"
echo "      cdevsw[49], [51], [52] free; z3660eth, zz9000, monsw absent; open: $U"

# ---------------------------------------------------------------- 1. the core (brief steps 1-6)
stage
PIN=gcc-$(awk '$1=="gcc"{print $2}' "$S/kit/toolchain.pin")-$(awk '$1=="commit"{print $2}' "$S/kit/toolchain.pin")
GCA=$(dirname "$GCC_CROSS_ENV")/..
git -C "$GCA" show "$(awk '$1=="commit"{print $2}' "$S/kit/toolchain.pin"):amix-gcc-wrapper.sh" 2>/dev/null \
	| sed 's/@TARGET@/m68k-cbm-sysv4/' | cmp -s - "$(command -v m68k-cbm-sysv4-gcc)" \
	|| { echo "[FAIL] the installed m68k-cbm-sysv4-gcc is not the wrapper of the pin $PIN"; exit 1; }
echo "[*] amix-dlm $(echo "$REV" | cut -c1-7): core b736c59 + $(grep -c '^[0-9]' "$S/kit/core/series") patches; kabi $DLM_KABI, pin $PIN"
KK=$(python3 - "$IN" <<'PY'
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
[ "$KK" = "$DLM_KABI" ] || { echo "[FAIL] the base's kinfo_kabi is '$KK', not $DLM_KABI (relink-040-kinfo.sh DLM=1)"; exit 1; }
O="$S/obj"
rm -f "$O"/*.o "$O"/*.warn
offs
echo "      mkoffs: $(grep -c '^#define' "$S/core/dlm_offs.h") layouts"
sh "$S/core/tools/mkreg" "$S/kit/abi/registry/majors" > "$S/core/dlmreg.c" || { echo "[FAIL] mkreg"; exit 1; }
KCC="m68k-cbm-sysv4-gcc $AMIX_KERNEL_CFLAGS -Wall -I$S/core/include -I$S/core"
LCC="m68k-cbm-sysv4-gcc -O2 -m68020 -fno-builtin -fomit-frame-pointer -Wall -I$S/kit/loader/common"
U1=; [ "${DLM_U1:-0}" = 1 ] && { U1=1; echo "      DLM_U1=1: the core carries the U1 probe -- a measurement build, never shipped"; }
CORE="dlm_core dlm_ld dlm_sym dlm_slot dlm_str dlmconf dlmreg dlm_arena dlm_post dlm_ddi dlm_intr"
for f in $CORE; do
	$KCC ${U1:+-DDLM_U1} -DDLM_KABI=\"$DLM_KABI\" -DDLM_PIN=\"$PIN\" -c "$S/core/$f.c" -o "$O/$f.o" 2>> "$O/kobj.warn"
done
for f in sha256 crc32; do $LCC -c "$S/kit/loader/common/$f.c" -o "$O/$f.o" 2>> "$O/kobj.warn"; done
$LCC -c "$S/kit/core/plat/amiga.c" -o "$O/plat-amiga.o" 2>> "$O/kobj.warn"
$LCC -c "$S/kit/core/plat/k46/line.c" -o "$O/plat-line.o" 2>> "$O/kobj.warn"
for f in dlm_cache dlm_hooksw dlm_spl; do m68k-cbm-sysv4-gcc -c "$S/core/$f.s" -o "$O/$f.o"; done
OTHER=$(grep -v 'types.h:182\|In file included\|^ *from ' "$O/kobj.warn" | grep . || true)
[ -z "$OTHER" ] || { echo "[FAIL] warnings beyond the stock headers':"; echo "$OTHER"; exit 1; }
python3 "$S/kit/tools/prfcheck.py" $(for f in $CORE; do echo "$S/core/$f.c"; done) "$S/kit/core/plat/amiga.c" \
	"$S/kit/core/plat/k46/line.c" > "$O/prf.log" || { cat "$O/prf.log"; echo "[FAIL] prfcheck"; exit 1; }
COREO=$(for f in $CORE sha256 crc32 plat-amiga plat-line dlm_cache dlm_hooksw dlm_spl; do echo "$O/$f.o"; done)
m68k-cbm-sysv4-ld -r -o "$O/dlm.o" $COREO
echo "      dlm.o: $(m68k-linux-gnu-size "$O/dlm.o" | awk 'NR==2{print $1 "+" $2 "+" $3}') text+data+bss, no warnings of its own, printf formats %d %x %s only"
# a core that reads dlm_static_root (core patch 0037) gets the kernel's built-in root controllers,
# the sidecar's root= list, beside the identity record: marc_root skips a module for one of them
SROOT=
if m68k-linux-gnu-nm "$O/dlm.o" | grep -qE " U dlm_static_root\$"; then
	SROOT=$(python3 "$HERE/tools/kabi-sidecar.py" --root "$IN")
	echo "      dlm_static_root: \"$SROOT\" (the controllers sd's table drives)"
	python3 "$S/kit/tools/mkident.py" --asm k46 "$DLM_KABI" "$DLM_ARENA" "$SROOT" > "$O/ident.s"
else
	python3 "$S/kit/tools/mkident.py" --asm k46 "$DLM_KABI" "$DLM_ARENA" > "$O/ident.s"
fi
# C3-3 version 5 (core a829c44): dlm_arena is capacity + 16 and --fill records its first 16-aligned
# image offset, so the arena's alignment comes from the record, not the section.  mkident's
# `.balign 16` before dlm_arena would make the core's .data 16-aligned, and .data follows .text
# unpadded in this image (the gate below): it becomes `.balign 4` here, the one change.
if grep -q '^	\.balign	16$' "$O/ident.s"; then
	awk '/^\t\.balign\t16$/ {getline nx; if (nx != "\t.globl\tdlm_arena") exit 1; print "\t.balign\t4"; print nx; n++; next}
	     {print} END {if (n != 1) exit 1}' "$O/ident.s" > "$O/ident.s.4" \
		|| { echo "[FAIL] ident.s: the .balign 16 is not the one before dlm_arena"; exit 1; }
	mv "$O/ident.s.4" "$O/ident.s"
	echo "      ident.s: dlm_arena's .balign 16 -> 4 (the record rounds the arena to 16, C3-3 v5)"
fi
m68k-cbm-sysv4-as -o "$O/ident.o" "$O/ident.s"
"$S/mkksym" -a "$S/kit/abi/k46/ddi.list" -a "$S/kit/abi/k46/core.list" > "$O/ksym.s" 2> "$O/ksym.log" \
	|| { echo "[FAIL] mkksym -a: $(cat "$O/ksym.log")"; exit 1; }
m68k-cbm-sysv4-as -o "$O/ksym.o" "$O/ksym.s"
echo "      ident.o: AXK1 + arena $DLM_ARENA; ksym.o: $(sed 's/^mkksym: //' "$O/ksym.log")"
DEVKV=
if echo "$NM_IN" | grep -qE " T dev_kvmap\$"; then
	echo "      dev_kvmap: in the base"
else
	DEVKV="$O/devkvmap040.o"
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/devkvmap040.s" -o "$DEVKV"
	echo "      dev_kvmap: not in the base -- linking src/devkvmap040.s"
fi
LIBGCC="$AMIX_CROSS/lib/gcc-lib/m68k-cbm-sysv4/2.7.2.3/libgcc.a"
[ -f "$LIBGCC" ] || { echo "[FAIL] no libgcc.a at $LIBGCC"; exit 1; }

# ---------------------------------------------------------------- 2. what the splice adds
echo "[*] ld -r: dlm.o + ident.o + ksym.o${DEVKV:+ + devkvmap040.o} + libgcc.a (the DDI's three)"
m68k-cbm-sysv4-ld -r -u __udivdi3 -u __umoddi3 -u __lshrdi3 -o "$O/add.o" \
	"$O/dlm.o" "$O/ident.o" "$O/ksym.o" $DEVKV "$LIBGCC"
. "$HERE/tools/fold-rodata.sh"
fold_rodata "$O/add.o"
for g in $(m68k-linux-gnu-readelf -SW "$O/add.o" | awk '{gsub(/[][]/,"")} $2 ~ /^\.(text|data|bss)$/ && $NF+0 > 4 && $2 != ".bss" {print $2 ":" $NF}'); do
	echo "[FAIL] $O/add.o: $g aligned above 4 -- .data follows .text directly in the image"; exit 1
done
echo "[*] 68060 instruction census of everything the splice adds"
run_step indent m68k-cbm-sysv4-scan060 "$O/add.o"
run_step indent sh "$HERE/src/check_page_geometry.sh" "$O/add.o"

# ---------------------------------------------------------------- 3. the splice
echo "[*] the base weakened where the core replaces it; the stock kept as __amix_*"
sym() { echo "$NM_IN" | awk -v n="$1" -v t="$2" '$3==n && $2==t {print $1}'; }
STAGE="$HERE/build/unix-stage-dlm"
cp "$IN" "$STAGE"
# a core that defines vfssw (core patch 0040, C4-6 section 2) replaces vfssw and nfstype too
VFSW=
if m68k-linux-gnu-nm "$O/add.o" | grep -qE " D vfssw\$"; then
	m68k-linux-gnu-nm "$O/add.o" | grep -qE " D nfstype\$" \
		|| { echo "[FAIL] the core defines vfssw but not nfstype"; exit 1; }
	VFSW="--weaken-symbol vfssw --weaken-symbol nfstype
	--add-symbol __amix_vfssw=.data:0x$(sym vfssw D),global,object
	--add-symbol __amix_nfstype=.data:0x$(sym nfstype D),global,object"
fi
m68k-linux-gnu-objcopy --weaken-symbol dmainit --weaken-symbol execsw --weaken-symbol fmodsw \
	--weaken-symbol scrcon_put --weaken-symbol aciabintr \
	--add-symbol __amix_execsw=.data:0x$(sym execsw D),global,object \
	--add-symbol __amix_fmodsw=.data:0x$(sym fmodsw D),global,object \
	--add-symbol __amix_scrcon_put=.text:0x$(sym scrcon_put T),global,function \
	--add-symbol __amix_aciabintr=.text:0x$(sym aciabintr T),global,function $VFSW "$STAGE"
echo "      execsw .data 0x$(sym execsw D), fmodsw .data 0x$(sym fmodsw D), scrcon_put .text 0x$(sym scrcon_put T), aciabintr .text 0x$(sym aciabintr T)"
[ -z "$VFSW" ] || echo "      vfssw .data 0x$(sym vfssw D), nfstype .data 0x$(sym nfstype D) (the core's grown vfssw, core patch 0040)"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/dlm_tail040.s" -o "$O/dlm_tail040.o"
# the halt pass (core patch 0030): a core that defines dlm_halt gets mdboot's two calls through it
SDSEAM=0
if m68k-linux-gnu-nm "$O/add.o" | grep -qE " T dlm_sd_close\$"; then
	echo "$NM_IN" | grep -qE " T sd4_noclose\$" \
		|| { echo "[FAIL] the core has sd_register (dlm_sd_close) but the base has no four-card sd -- run relink-040-sd4card.sh"; exit 1; }
	SDSEAM=1
	echo "      dlm_sd_close: in the core -- sd4_init takes the module registrations through it"
fi
MARC=0
if m68k-linux-gnu-nm "$O/add.o" | grep -qE " T dlm_marc_root\$"; then
	echo "$NM_IN" | grep -qE " T rth1_nomarc\$" \
		|| { echo "[FAIL] the core has dlm_marc_root but the base has no rth1_nomarc -- relink-040-rth1.sh DLM=1 at this revision"; exit 1; }
	MARC=1
	echo "      dlm_marc_root: in the core -- rth1_mountroot calls it before rth1_apply"
fi
FREEB20=0
case "$DLM_KABI" in k46.1.0) ;; *) FREEB20=1; echo "      $DLM_KABI: bdevsw[20] (the stock RAM disk) freed for the module ramdisk";; esac
HALTO=
if m68k-linux-gnu-nm "$O/add.o" | grep -qE " T dlm_halt\$"; then
	HALTO="$O/dlm_halt040.o"
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/dlm_halt040.s" -o "$HALTO"
	echo "      dlm_halt: in the core -- mdboot's haltsys and rtnfirm calls go through it (dlm_halt040.o)"
fi
# a release edit of the module kernel: the fault resolver's FAILEXIT line behind krnx_fail_print (0)
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/krnx_quiet040.s" -o "$O/krnx_quiet040.o"
echo "[*] ld -r: base + the core${HALTO:+ + dlm_halt040.o} + krnx_quiet040.o + dlm_tail040.o (LAST: the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$O/add.o" $HALTO "$O/krnx_quiet040.o" "$O/dlm_tail040.o"
NM_OUT=$(m68k-linux-gnu-nm "$OUT")
LEAK=$(echo "$NM_OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols but etext, edata, end"
WEAK=$(echo "$NM_OUT" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] weak symbols survive the splice: $WEAK"; exit 1; }
echo "[OK] no weak symbol"
run_step indent python3 "$HERE/src/check_dlm_splice.py" "$IN" "$OUT"
run_step indent python3 "$HERE/src/check_dlm_splice.py" --free-rows 49,51,52 "$OUT"
if [ -n "$HALTO" ]; then
	run_step indent python3 "$HERE/src/patch_dlm_halt.py" "$OUT"
	run_step indent python3 "$HERE/src/patch_dlm_halt.py" --check "$OUT"
fi
if [ $SDSEAM = 1 ]; then
	run_step indent python3 "$HERE/src/patch_dlm_call.py" "$OUT" sd4_init sd4_noclose dlm_sd_close
	run_step indent python3 "$HERE/src/patch_dlm_call.py" --check "$OUT" sd4_init sd4_noclose dlm_sd_close
fi
if [ $MARC = 1 ]; then
	run_step indent python3 "$HERE/src/patch_dlm_call.py" "$OUT" rth1_mountroot rth1_nomarc dlm_marc_root
	run_step indent python3 "$HERE/src/patch_dlm_call.py" --check "$OUT" rth1_mountroot rth1_nomarc dlm_marc_root
fi
run_step indent python3 "$HERE/src/patch_krnx_quiet.py" "$OUT"
run_step indent python3 "$HERE/src/patch_krnx_quiet.py" --check "$OUT"
if [ $FREEB20 = 1 ]; then
	run_step indent python3 "$HERE/src/patch_free_brow.py" "$OUT"
	run_step indent python3 "$HERE/src/patch_free_brow.py" --check "$OUT"
fi

# ---------------------------------------------------------------- 4. packaging guards
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	$2==".rodata" {r=1}
	END{print to, ts, do_, r+0}')
set -- $CONTIG
[ "$4" = 0 ] || { echo "[FAIL] $OUT carries .rodata"; exit 1; }
TSZ=$(( 0x$2 ))
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
[ "$1" = "$2" ] && echo "[OK] text/data contiguous." \
	|| { echo "[FAIL] text/data NOT contiguous"; exit 1; }
[ $((TSZ % 4)) -eq 0 ] && echo "[OK] .text size 0x$(printf %x $TSZ) is 4-aligned." \
	|| { echo "[FAIL] .text size not 4-aligned -- is dlm_tail040.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     next:  relink-040-fpe.sh (always the last link); relink-040-dlm.sh --fill after the W-D7 inject"
