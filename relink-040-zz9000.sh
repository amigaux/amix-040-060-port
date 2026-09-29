#!/bin/sh
# relink-040-zz9000.sh -- link the Z3660 RTG driver (zz9000, char major 49) into a kernel of
# the z3660 lineage, so /dev/zz9000 opens on the A4000 + Z3660 (2026-09-15).
#
#   the amix-z3660rtg repository   the isoriano zz9000 driver, Z3660 board row
#                                  (one K&R C file, no asm; entry points zz9000open/close/
#                                  read/write/ioctl/mmap, boot probe zz9000init)
#
# The upstream repository is a SEPARATE PROJECT and is never modified: zz9000.c and zz9000.h
# are copied into build/ and compiled there, through the Model-B mirror sysroot, with the
# same dialect every other C file linked into this kernel gets.  The driver computes its
# PFNs with the phystopfn() macro, so the header set alone gives it the 4 KiB shift and no
# source rewrite is needed (contrast va2000_modelb.py, which exists for a literal `>> 11`);
# check_page_geometry.sh asserts that in the compiled bytes anyway.
#
# Registration is the VA2000 shape (relink-040-va2000.sh), with two differences that are
# the point of this script:
#
#   1. cdevsw[49] instead of cdevsw[68] -- src/patch_zz9000_cdevsw.py retargets the six
#      `nodev` relocations of the free row 49 (asserted free, never overwritten).
#
#   2. The base's `parinit` is ALREADY a wrapper.  Every kernel of the z3660 lineage carries
#      src/z3660_glue040.s's parinit (the zen0 streamtab store) chained to the stock body,
#      exposed as `parinit_orig`.  relink-040-va2000.sh assumes it is the first and only owner
#      of parinit (PARINIT_ADDR=0xfe6c, and it adds the name `parinit_orig` itself), so it
#      cannot run over this lineage.  Here the address of the CURRENT strong parinit is read
#      from nm of the base -- never from a note, it moves with every build -- and exposed under
#      a new alias, parinit_zz9000_orig, which src/parinit_zz9000.s chains to.  The chain at
#      run time is io_init[0] -> zz9000 wrapper -> z3660 wrapper -> stock parinit; reaching
#      past the z3660 wrapper would silently unregister zen0, so `parinit_orig` is asserted
#      untouched afterwards.
#
# This is a post-pass in the f7 sense: it runs over the pinned f6 output (build/unix-040-f7vs,
# the base r13 was built from) and its output is what relink-040-fpe.sh is then run over, so
# the FPE pass's own guards (.text 4-alignment, check_fpe_relocs, the root-storage family)
# cover the whole artifact and the FPE remains the last link.  The two .data stamps
# (tools/stamp-card1.py, tools/stamp-cputype.py) follow as for r13.
#
# Two gates here are new to this tree and deliberate:
#   * test-tools/scan060.py over the compiled driver object.  gcc 2.7.2.3 at -O turns a
#     division or modulo by a constant into the 64-bit multiply the 68060 does not implement,
#     and src/isp61_060.s emulates that only for user-mode frames -- a supervisor-mode hit
#     goes to nullvect.  A driver object is kernel mode, so the scan is a gate, not advice.
#   * the driver's unresolved-import set must be EXACTLY the seven kernel symbols it is known
#     to need.  A surprise import that ld -r happens to resolve is a driver reaching into the
#     kernel somewhere nobody has looked.
#
# usage: sh relink-040-zz9000.sh [base-kernel] [output]
#   ZZ9000_REV=<git rev>    take zz9000.c/.h from that revision of the driver repository
#                           (the pass log records which).  Default: the pin below; ZZ9000_REV=
#                           (empty) takes the checkout's working tree instead
#   ZZ9000_OPTS="..."       extra single-token driver options, e.g. -DZZ9K_Z3660_CON_1280x800
#                           -DZZ9K_MONSW (RT-04): switch through the base's /dev/monsw; needs relink-040-monsw.sh first
#                           -DZZ9K_FB_NC (RT-05): register the framebuffer NC via hat_cm_fb_add
#   ZZ9000_BASE_SHA256=<hex> refuse any base but that one (the pinned f7vs is
#                           d43a59ccb7df2ebcdf611a7fa322dd84a4c2166fa9d491078025ef4f9e0fa889)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tools/config-load.sh"
. "$HERE/tools/build-step.sh"

IN="${1:-$HERE/build/unix-040-f7vs}"
OUT="${2:-$HERE/build/unix-040-f7vs-zz9000}"
[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-readelf -h "$IN" >/dev/null 2>&1 || { echo "ERROR: $IN is not an ELF object"; exit 1; }
BASESHA=$(sha256sum "$IN" | cut -d' ' -f1)
echo "[*] base: $(basename "$IN")  (sha256 $BASESHA)"
[ -z "$ZZ9000_BASE_SHA256" ] || [ "$ZZ9000_BASE_SHA256" = "$BASESHA" ] \
	|| { echo "[FAIL] base sha256 $BASESHA is not the pinned $ZZ9000_BASE_SHA256"; exit 1; }

[ -n "$ZZ9000_SRC" ] || { echo "ERROR: ZZ9000_SRC is not set -- point it at the zz9000 driver directory in config.sh"; exit 1; }
[ -d "$ZZ9000_SRC" ] || { echo "ERROR: ZZ9000_SRC is not a directory: $ZZ9000_SRC"; exit 1; }

# ---------------------------------------------------------------- 0. the base's shape
# This pass belongs to the z3660 lineage and nowhere else: the driver shares the board's
# register page with zen0 and its probe reads the fixed base the SCSI mailbox lives behind.
m68k-linux-gnu-nm "$IN" | grep -qE " [TtDdBb] z3660queue\$" \
	|| { echo "[FAIL] $IN has no z3660queue -- this pass belongs after relink-040-z3660.sh"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpsp_vec11\$" \
	|| { echo "[FAIL] base does NOT carry FPSP -- rebuild the base with relink-040.sh"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] zz9000init\$" \
	&& { echo "[FAIL] base already has zz9000 linked -- use a plain base"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpe_vec11\$" \
	&& { echo "[FAIL] base already carries the FPE -- this pass runs BEFORE relink-040-fpe.sh"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE " parinit_zz9000_orig\$" \
	&& { echo "[FAIL] base already carries parinit_zz9000_orig -- objcopy would add a second one silently"; exit 1; }
# A finished kernel has no weak symbols.  A stage file (unix-stage-*) does: it is a base with an
# override weakened and the override NOT yet linked, and every other guard here passes it.
WEAK=$(m68k-linux-gnu-nm "$IN" | awk '$2 ~ /^[WwVv]$/ {print $3}')
[ -z "$WEAK" ] || { echo "[FAIL] $IN carries weak symbols -- a stage file, not a finished base:"; echo "$WEAK" | sed 's/^/      /'; exit 1; }

# The base's parinit must be the z3660 wrapper, i.e. a strong parinit that is NOT the stock
# body and a parinit_orig that is.  Its address is what the new wrapper chains to.
PARINIT_CUR=$(m68k-linux-gnu-nm "$IN" | awk '$3=="parinit" && $2=="T"{print $1}')
PARINIT_STOCK=$(m68k-linux-gnu-nm "$IN" | awk '$3=="parinit_orig" && $2=="T"{print $1}')
[ -n "$PARINIT_CUR" ]   || { echo "ERROR: no strong parinit in $IN"; exit 1; }
[ -n "$PARINIT_STOCK" ] || { echo "ERROR: no parinit_orig in $IN -- the base's parinit is not the z3660 wrapper"; exit 1; }
[ "$PARINIT_CUR" != "$PARINIT_STOCK" ] || { echo "ERROR: parinit == parinit_orig in $IN"; exit 1; }
[ "$(echo "$PARINIT_CUR" | wc -w)" = 1 ] || { echo "ERROR: more than one strong parinit in $IN"; exit 1; }
echo "      parinit (the base's current wrapper: z3660, or monsw over it) @0x$PARINIT_CUR, stock body parinit_orig @0x$PARINIT_STOCK"

# ---------------------------------------------------------------- 1. the header set
echo "[*] Model-B header set (mirror sysroot + geometry probe)"
sh "$HERE/src/mk_modelb_sysroot.sh" | sed 's/^/      /'
AMIX_SYSROOT="$HERE/build/sysroot-modelb"
export AMIX_SYSROOT

# ---------------------------------------------------------------- 2. the driver source
# zz9000.c includes "../../console/screen.h" and "../../console/console.h" relative to its
# own directory and the stock tree's amiga/inc through -I, so it is compiled from a copy that
# sits where the driver sits in a kernel tree: sys/amiga/driver/zz9000 beside sys/amiga/console
# and sys/amiga/inc (the cross sysroot ships both).  A symlinked driver directory would resolve
# the ../.. paths against the upstream repository instead, hence a copy.
TREE="$HERE/build/zz9000-tree/sys"
DRV="$TREE/amiga/driver/zz9000"
rm -rf "$HERE/build/zz9000-tree"
mkdir -p "$DRV"
ln -s "$AMIX_SYSROOT/usr/sys/amiga/console" "$TREE/amiga/console"
ln -s "$AMIX_SYSROOT/usr/sys/amiga/inc"     "$TREE/amiga/inc"
ln -s "$AMIX_SYSROOT/usr/include/sys"       "$TREE/sys"
[ -f "$TREE/amiga/console/screen.h" ] && [ -f "$TREE/amiga/inc/amiga.h" ] \
	|| { echo "ERROR: the sysroot has no usr/sys/amiga/console or usr/sys/amiga/inc"; exit 1; }
# Pinned (PO-13b, 2026-09-29): amix-z3660rtg 729cbdc -- the card-blitter path (RT-07, e23712d), its
# fill colour in the RGB register's high half (c9aeb18) and the svga_switch reset at last close.
# zz9000_040.o: -DZZ9K_MONSW 08500bbb..., plain 3b175753...  Imports unchanged; the knobs
# zz9k_blit_on / zz9k_blit_maxarea sit in .data for image patching.
ZZ9000_REV="${ZZ9000_REV-729cbdc}"
if [ -n "$ZZ9000_REV" ]; then
	REPO=$(git -C "$ZZ9000_SRC" rev-parse --show-toplevel)
	REL=$(git -C "$ZZ9000_SRC" rev-parse --show-prefix)
	for f in zz9000.c zz9000.h; do
		git -C "$REPO" cat-file -e "$ZZ9000_REV:$REL$f" \
			|| { echo "ERROR: $REL$f does not exist at $ZZ9000_REV in $REPO"; exit 1; }
		git -C "$REPO" show "$ZZ9000_REV:$REL$f" > "$DRV/$f"
	done
	SRCID="$(git -C "$REPO" rev-parse "$ZZ9000_REV") ($ZZ9000_REV, from the repository)"
else
	[ -f "$ZZ9000_SRC/zz9000.c" ] && [ -f "$ZZ9000_SRC/zz9000.h" ] \
		|| { echo "ERROR: $ZZ9000_SRC does not hold zz9000.c and zz9000.h"; exit 1; }
	cp "$ZZ9000_SRC/zz9000.c" "$ZZ9000_SRC/zz9000.h" "$DRV/"
	SRCID="working tree $ZZ9000_SRC"
	# Under set -e a command substitution's status is the status of its LAST command, so the
	# modified-or-not question is asked in its own statements, never inside the assignment.
	HEADREV=$(git -C "$ZZ9000_SRC" rev-parse HEAD 2>/dev/null || true)
	if [ -n "$HEADREV" ]; then
		MOD=$(git -C "$ZZ9000_SRC" status --porcelain -- zz9000.c zz9000.h 2>/dev/null || true)
		SRCID="$SRCID @ $HEADREV"
		[ -z "$MOD" ] || SRCID="$SRCID (MODIFIED)"
	fi
fi
echo "[*] driver source: $SRCID"
sha256sum "$DRV/zz9000.c" "$DRV/zz9000.h" | sed 's/^/      /'

# ---------------------------------------------------------------- 3. the compile
# The Z3660 board row, no bench aid (ZZ9K_BENCH_* are for the emulator only and never for a
# shipped kernel), no font object: the kernel has no `builtinfont` symbol and the driver's
# console falls back to its own glyphs under ZZ9K_NO_BUILTINFONT.
echo "[*] cross-compiling the driver (-m68040 dialect, Model-B headers)"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
(cd "$DRV" && m68k-cbm-sysv4-gcc $CF -DZZ9K_TARGET_Z3660 -DZZ9K_NO_BUILTINFONT $ZZ9000_OPTS \
	-I../../.. -I../../inc -c zz9000.c -o "$HERE/build/zz9000_040.o")
m68k-linux-gnu-size "$HERE/build/zz9000_040.o" | sed 's/^/      /'
run_step indent sh "$HERE/src/check_page_geometry.sh" "$HERE/build/zz9000_040.o"
# T-9 (2026-09-28): -traditional makes the stock <sys/types.h> define `volatile` away, and gcc
# then deletes every spl()/splx() whose output is unused and every MMIO `volatile`.  The toolchain
# passes -Dvolatile=__volatile__ now; tools/spl-gate.py proves it for this object: G1 = the macro
# dump keeps `volatile`, G2 = every function that calls spl writes %sr (per function).
# The driver's own ZZ9K_SPLTTY/ZZ9K_SPLX expand to asm (or to nothing), so they are counted in the
# raw source; the gate preprocesses from the driver's directory with the compile's own flags.
echo "[*] T-9 gates G1/G2 (spl masks and MMIO volatile survived -traditional)"
run_step all python3 "$HERE/tools/spl-gate.py" --object "$HERE/build/zz9000_040.o" \
	--source zz9000.c --cwd "$DRV" --cflags "$CF" --macro ZZ9K_SPLTTY --macro ZZ9K_SPLX \
	-- -DZZ9K_TARGET_Z3660 -DZZ9K_NO_BUILTINFONT $ZZ9000_OPTS -I../../.. -I../../inc
LC_ALL=C m68k-linux-gnu-objdump -d "$HERE/build/zz9000_040.o" | grep -A1 "moveq #12," | grep -q "lsrl" \
	|| { echo "[FAIL] zz9000_040.o has no 4 KiB page shift at all -- phystopfn not from the Model-B headers?"; exit 1; }

echo "[*] 68060 instruction census of the driver object (kernel mode: nothing emulates a hit)"
LC_ALL=C m68k-linux-gnu-objdump -d "$HERE/build/zz9000_040.o" > "$HERE/build/zz9000_040.lst"
run_step all python3 "$HERE/test-tools/scan060.py" "$HERE/build/zz9000_040.lst"
# scan060.py is an instrument: it reports, it does not exit non-zero.  So the gate is read off
# its two verdict lines -- "CLEAN -- no candidate found" or "total candidates: N" -- and output
# carrying neither is refused, as is a listing it could not decode at all ("0 decoded lines" is
# also CLEAN).  A candidate is a list entry to be read, not yet an instruction, but a kernel
# object is not the place to read it: any candidate stops the build.  Second run because
# run_step owns its output (tools/build-step.sh).
SCAN=$(python3 "$HERE/test-tools/scan060.py" "$HERE/build/zz9000_040.lst")
SCANLINES=$(echo "$SCAN" | sed -n 's/.*(\([0-9][0-9]*\) decoded lines).*/\1/p')
if echo "$SCAN" | grep -q 'CLEAN -- no candidate found'; then
	SCANHITS=0
else
	SCANHITS=$(echo "$SCAN" | sed -n 's/.*total candidates: *\([0-9][0-9]*\).*/\1/p')
fi
[ -n "$SCANLINES" ] && [ "$SCANLINES" -gt 100 ] \
	|| { echo "[FAIL] scan060 decoded ${SCANLINES:-0} lines of zz9000_040.lst -- not a listing it understood"; exit 1; }
[ "$SCANHITS" = 0 ] || { echo "[FAIL] scan060: ${SCANHITS:-an unrecognised report,} 060-unimplemented candidate(s) in zz9000_040.o"; exit 1; }

echo "[*] the driver's kernel imports must be exactly the seven it is known to need"
# ... plus exactly monsw_lastclose/monsw_register/monsw_set when built with -DZZ9K_MONSW (RT-04,
# amix-z3660rtg 7b449cd): the monitor switch then belongs to /dev/monsw, which the base must
# already carry -- relink-040-monsw.sh runs before this pass (dd -> z3660 -> monsw -> zz9000 -> fpe).
# ... and hat_cm_fb_add on top when built with -DZZ9K_FB_NC (RT-05, amix-z3660rtg 26ff2d0): the
# driver registers its framebuffer window in the base's hat_cm_fb table, so user mappings of it
# take the NC cache class instead of NCS.  That table is this line's hat040.s; a base without it
# is refused.
WANT="autocon bootinfo conputc copyin copyout printf uiomove"
case " $ZZ9000_OPTS " in
*" -DZZ9K_MONSW "*)
	WANT="$WANT monsw_lastclose monsw_register monsw_set"
	m68k-linux-gnu-nm "$IN" | grep -qE " T monswinit\$" \
		|| { echo "[FAIL] -DZZ9K_MONSW needs a base with /dev/monsw -- run relink-040-monsw.sh first"; exit 1; }
	echo "      (-DZZ9K_MONSW: the monitor switch goes through the base's monsw)" ;;
esac
case " $ZZ9000_OPTS " in
*" -DZZ9K_FB_NC "*)
	WANT="$WANT hat_cm_fb_add"
	m68k-linux-gnu-nm "$IN" | grep -qE " T hat_cm_fb_add\$" \
		|| { echo "[FAIL] -DZZ9K_FB_NC needs a base that exports hat_cm_fb_add (this line's hat040.s)"; exit 1; }
	echo "      (-DZZ9K_FB_NC: the framebuffer registers as NC through the base's hat_cm_fb_add)" ;;
esac
WANT=$(echo $WANT | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
GOT=$(m68k-linux-gnu-nm "$HERE/build/zz9000_040.o" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] || { echo "[FAIL] unresolved set is: $GOT"; echo "       expected:          $WANT"; exit 1; }
echo "      $GOT"
for s in zz9000open zz9000close zz9000read zz9000write zz9000ioctl zz9000mmap zz9000init; do
	m68k-linux-gnu-nm "$HERE/build/zz9000_040.o" | grep -qE " T $s\$" || { echo "[FAIL] $s not exported by zz9000_040.o"; exit 1; }
done
echo "      exports: zz9000open/close/read/write/ioctl/mmap + zz9000init"
# ... and the other direction.  ld -r reports two STRONG definitions of one name, but it merges a
# COMMON (an uninitialised global; the kernel dialect has no -fno-common) with a same-named kernel
# object silently, and it would rebind every stock call site to a driver definition of a name the
# base carries weak.  So: no COMMON symbols in the driver, and no name it defines may already exist.
COMMONS=$(m68k-linux-gnu-nm "$HERE/build/zz9000_040.o" | awk '$2=="C"{print $3}')
[ -z "$COMMONS" ] || { echo "[FAIL] zz9000_040.o has COMMON symbols (ld -r would merge them with the kernel's):"; echo "$COMMONS" | sed 's/^/      /'; exit 1; }
m68k-linux-gnu-nm "$HERE/build/zz9000_040.o" | awk '$2 ~ /^[TDBR]$/{print $3}' | LC_ALL=C sort > "$HERE/build/zz9000_040.defs"
m68k-linux-gnu-nm "$IN" | awk 'NF==3{print $3}' | LC_ALL=C sort -u > "$HERE/build/zz9000-base.names"
DUP=$(LC_ALL=C comm -12 "$HERE/build/zz9000_040.defs" "$HERE/build/zz9000-base.names")
[ -z "$DUP" ] || { echo "[FAIL] zz9000_040.o defines names the base already has:"; echo "$DUP" | sed 's/^/      /'; exit 1; }
echo "      no COMMON symbols; no definition collides with a name in the base"

echo "[*] assembling the parinit wrapper"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/parinit_zz9000.s" -o "$HERE/build/parinit_zz9000.o"

# ---------------------------------------------------------------- 4. the link
echo "[*] weaken the base's parinit, expose it as parinit_zz9000_orig @0x$PARINIT_CUR"
STAGE="$HERE/build/unix-stage-zz9000"
cp "$IN" "$STAGE"
m68k-linux-gnu-objcopy \
	--weaken-symbol parinit \
	--add-symbol parinit_zz9000_orig=.text:0x${PARINIT_CUR},function,global \
	"$STAGE"

# ORDER MATTERS: a compiled object is not guaranteed to end its sections on a 4-byte boundary
# (this one's .data is 2 mod 4); the wrapper carries the .balign 4 for both .text and .data, so
# it is linked LAST.
echo "[*] ld -r: base + zz9000_040.o + parinit_zz9000.o (wrapper LAST: it carries the .balign 4)"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" "$HERE/build/zz9000_040.o" "$HERE/build/parinit_zz9000.o"

# ---------------------------------------------------------------- 5. symbol assertions
echo "[*] symbols that must be defined:"
# grep -q decides; the listing line is printed separately, because `grep | sed || fail` can never
# fail -- sed's status is the pipeline's (tools/build-step.sh, the same lesson one layer down).
for s in zz9000open zz9000close zz9000read zz9000write zz9000ioctl zz9000mmap zz9000init \
	 parinit parinit_zz9000_orig parinit_orig z3660ethinfo z3660queue; do
	m68k-linux-gnu-nm "$OUT" | grep -qE " [TtDdBb] $s\$" || { echo "[FAIL] $s not defined"; exit 1; }
	m68k-linux-gnu-nm "$OUT" | grep -E " [TtDdBb] $s\$" | sed "s/^/      /"
done

# The override actually moved: exactly one strong parinit, ours, above the base's .text end
# (`ld -r` links cleanly with the stock body still strong when an override is dropped).
BASETEXT=$(( 0x$(m68k-linux-gnu-readelf -SW "$STAGE" | awk '{gsub(/[][]/,"")} $2==".text"{print $6}') ))
PARINIT_NEW=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="parinit" && $2=="T"{print $1}')
[ "$(echo "$PARINIT_NEW" | wc -w)" = 1 ] || { echo "[FAIL] expected exactly 1 strong parinit, found: $PARINIT_NEW"; exit 1; }
[ $(( 0x$PARINIT_NEW )) -ge "$BASETEXT" ] || { echo "[FAIL] parinit still resolves into the base at 0x$PARINIT_NEW"; exit 1; }
echo "      parinit overridden (0x$PARINIT_NEW, past the base's .text end 0x$(printf %x $BASETEXT))"
# ... and the chain below it is intact: the alias names the z3660 wrapper, the stock body is
# still exposed where it was.
A=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="parinit_zz9000_orig"{print $1}')
[ "$A" = "$PARINIT_CUR" ] || { echo "[FAIL] parinit_zz9000_orig @0x$A != the base's wrapper @0x$PARINIT_CUR"; exit 1; }
A=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="parinit_orig"{print $1}')
[ "$A" = "$PARINIT_STOCK" ] || { echo "[FAIL] parinit_orig moved: 0x$A != 0x$PARINIT_STOCK"; exit 1; }
echo "      chain: parinit -> parinit_zz9000_orig (the base's wrapper @0x$PARINIT_CUR) -> parinit_orig (stock @0x$PARINIT_STOCK)"

LEAK=$(m68k-linux-gnu-nm "$OUT" | awk '$1=="U" && $2!="edata" && $2!="end" && $2!="etext" {print $2}')
[ -z "$LEAK" ] || { echo "[FAIL] unresolved symbols:"; echo "$LEAK"; exit 1; }
echo "[OK] no unresolved symbols"
case " $ZZ9000_OPTS " in
*" -DZZ9K_FB_NC "*)
	N=$(m68k-linux-gnu-readelf -rW "$OUT" | awk '/^Relocation section .\.rela\.text/{t=1;next} /^Relocation section/{t=0} t && $5=="hat_cm_fb_add"' | wc -l)
	D=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="hat_cm_fb_add" && $2=="T"{print $1}')
	[ "$N" -ge 1 ] && [ -n "$D" ] \
		|| { echo "[FAIL] -DZZ9K_FB_NC: no call to a defined hat_cm_fb_add in $OUT"; exit 1; }
	echo "[OK] framebuffer NC registration linked: hat_cm_fb_add T @0x$D, $N .rela.text reference(s)" ;;
esac

# ---------------------------------------------------------------- 6. registration
echo "[*] cdevsw[49] -> zz9000* (major 49 = /dev/zz9000)"
run_step all python3 "$HERE/src/patch_zz9000_cdevsw.py" "$OUT"

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
	|| { echo "[FAIL] .text size not 4-aligned -- is parinit_zz9000.o last in the link?"; exit 1; }
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned." \
	|| { echo "[FAIL] .data size not 4-aligned -> .bss misaligned at runtime"; exit 1; }
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT"
echo "     driver: $SRCID"
echo "     next:   sh relink-040-fpe.sh $OUT <fpe-output>; then tools/stamp-card1.py and"
echo "             tools/stamp-cputype.py --set 60, exactly as for r13"
echo "     node:   mknod /dev/zz9000 c 49 0"
echo "     NOTE:   zz9000init reads the board's version register at the fixed base at io_init"
echo "             time; with no board answering there that read is a supervisor bus error."
