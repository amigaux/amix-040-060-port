#!/bin/bash
# cut.sh OUT -- cut 68060-261106-66 (the k46 module kernel, kabi k46.1.4) into OUT: -65's recipe with this repository at 67c347c
# (-65's 53e52e4 plus the audio driver answering each volume/period ioctl once, refusing a zero-length one without the
# NULL pullup, and its refills moving on, src/patch_audio_replies.py after amix-paula's three patchers);
# -65 was -64's recipe with this repository at 53e52e4
# (-64's fa24df6 plus a raw disk request past its slice end failing with ENXIO, src/patch_ddeof.py; and the ufs module's rwip
# calling ufs_bmap_hf, which zeroes a new block in a hole and keeps alloc-only rewrites, tools/ufs-holefix.sh after the tail
# zeroing);
# -64 was -63's recipe with this repository at fa24df6
# (-63's 0508945 plus the ufs module's rwip fix: segmap_pagecreate gets base + mapon, tools/fsobj-patch.py);
# -63 was -62's recipe with this repository at 0508945
# (-62's 84b0623 plus the 8 MiB kernel arena, the oversize wakeups, IP's lower read queue, a user page below 1 GiB in vtop and
# hardbus, the swap guard's resize path) and amix 46ef7d1; -62 was -61's recipe at 84b0623 (-61's a483e89 plus the carve keeping a core-tier COMMON in the kernel, src/carve_fs040.py)
# and amix 46ef7d1 (the kmem readers' five COMMONs in the core tier, the empty inode window, kbootset-min -37).
# -61 was -60's 422efc5 plus the 68040's pending write-backs kept across the signal of an
# unresolved user fault and completed when setcontext restores that context, src/wbkeep040.s; -60's 422efc5 was
# -59's plus sdqueue at IPL 2 at least, src/sdqspl040.s, the a3091 first-use
# hang; the A1200's Gayle port as motherboard id 2 in rth1 and kinfo; pstart's CACR/Ramsey boot dump only with
# btrace_on; pstart sets cputype from the k46 loader's AXL1 record) and amix 46c269c, as -59;
# gcc14's binutils (2.43.1) as m68k-linux-gnu-*, as -59.
# Inputs, by environment:
#   PORT_GIT     a clone of this repository that has 67c347c and the patcher revisions below (default: this one)
#   AMIX         an amix clone that has 46ef7d1 (kernel/dlm: the module core and `make kit`; kernel/k30/tools and
#                contracts: sddevsize and support-probe injectors, emit-family-chains, k0-gates; toolchain/m68k-gnu-bin)
#   PAULA        amix-paula with 62fdcab (the audio driver's three patchers)
#   GCA          gcc-cross-amix's build/ (env.sh; kernel/dlm/toolchain.pin, gcc 2.7.2.3 33ebadc), inside
#                a git checkout that has 33ebadc (relink-040-dlm.sh checks the installed wrapper against it)
#   G14          optional: gcc14-cross-amix's build/; given, amix's toolchain/m68k-gnu-bin makes the
#                m68k-linux-gnu-* links to its m68k-elf-* and puts them first on PATH; not given, PATH must
#                already carry them.  Either way the assembler and linker must be binutils 2.43.1.
#   AMIX_SYSTEM  amigaux/amix-system (kernels/2.1c/unix, the stock kernel the relinks check against)
#   NETBSD_SYSSRC  NetBSD 10.1's source/sets/syssrc.tgz (the FPSP; tools/netbsd-pin.sh checks its sha256)
#   CONTROL      optional: the frozen candidate-3 kernel (5aa7d732) emit and k0-gates compare against
# OUT gets the run root (port/ = git archive 67c347c, the build tree; amix-040-060-port/ = a clone at 67c347c;
# amix/ = a clone at 46ef7d1, its kernel/dlm the kit; amix-kerntools/ = 46ef7d1's kernel/k30 tools and
# contracts; gnu-bin/; inputs/) and SHA256SUMS-68060-261106-66, which must equal this directory's.
set -eu
REV=67c347c AMIX_REV=46ef7d1 KB=68060-261106-66
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:?usage: cut.sh OUT}; PORT_GIT=${PORT_GIT:-$(git -C "$HERE" rev-parse --show-toplevel)}
: "${AMIX:?}" "${PAULA:?}" "${GCA:?}" "${AMIX_SYSTEM:?}" "${NETBSD_SYSSRC:?}"; [ -z "${KT:-}" ] || { echo "cut.sh: KT must be unset"; exit 2; }
mkdir -p "$W"; W=$(cd "$W" && pwd); [ -z "$(ls -A "$W")" ] || { echo "cut.sh: $W is not empty"; exit 2; }
. "$GCA/env.sh"; CROSS=$AMIX_CROSS_PREFIX
if [ -n "${G14:-}" ]; then
	git -C "$AMIX" show $AMIX_REV:toolchain/m68k-gnu-bin > "$W/m68k-gnu-bin"
	G14=$G14 sh "$W/m68k-gnu-bin" "$W/gnu-bin" > /dev/null; PATH=$W/gnu-bin:$PATH
fi
for t in as ld; do
	m68k-linux-gnu-$t --version | head -n 1 | grep -q ' 2\.43\.1$' \
		|| { echo "cut.sh: m68k-linux-gnu-$t is not binutils 2.43.1 (gcc14's; set G14)"; exit 2; }
done
GNU=$(dirname "$(command -v m68k-linux-gnu-nm)")
# every rm/mv of a variable path in this recipe takes the ${var:?} guard; a cut copied from this one inherits the check
sh "$PORT_GIT/tools/lint-rm-guard.sh" "$HERE"/*.sh > /dev/null || { sh "$PORT_GIT/tools/lint-rm-guard.sh" "$HERE"/*.sh; exit 2; }
mkdir -p "$W/log"

# the build tree: the archive, a config.sh naming the inputs, the stamper shim and the block pin
mkdir -p "$W/port" "$W/stock/amix-2.1c/stand"
git -C "$PORT_GIT" archive $REV | tar -x -C "$W/port"
cp "$AMIX_SYSTEM/kernels/2.1c/unix" "$W/stock/amix-2.1c/stand/unix"
[ "$(sha256sum < "$W/stock/amix-2.1c/stand/unix" | cut -c1-16)" = 80a1204f4ec422f3 ] || { echo "cut.sh: not the 2.1c unix"; exit 1; }
cat > "$W/port/config.sh" <<EOF
AMIX_BUILD="$W/stock"
AMIX_CROSS="$CROSS"
GCC_CROSS_ENV="$GCA/env.sh"
M68K_GNU_BIN="$GNU"
AMIX_ROOT="\$AMIX_BUILD/amix-2.1c"
NETBSD_SYSSRC="$NETBSD_SYSSRC"
EOF
mv "${W:?}/port/src/stamp_buildid.py" "${W:?}/port/src/stamp_buildid.real.py"
cp "$HERE/stamp_buildid.py" "$W/port/src/stamp_buildid.py"; cp "$HERE/blocks.py" "$W/port/tools/blocks.py"
mkdir -p "$W/port/build"; echo "261106 65" > "$W/port/build/.build-seq"

# the siblings the kit and the family tools find: the port clone, the amix clone, the tools (in the directory
# kerntools' layout names), the toolchain
git clone -q "$PORT_GIT" "$W/amix-040-060-port"; git -C "$W/amix-040-060-port" checkout -q --detach $REV
cp "$W/port/config.sh" "$W/amix-040-060-port/config.sh"     # k0-gates runs its tools/status-facts.sh
git clone -q "$AMIX" "$W/amix"; git -C "$W/amix" checkout -q --detach $AMIX_REV
mkdir -p "$W/amix-kerntools"; git -C "$AMIX" archive $AMIX_REV kernel/k30/tools kernel/k30/contracts | tar -x --strip-components=2 -C "$W/amix-kerntools"
mkdir -p "$W/gcc-cross-amix"; ln -s "$GCA" "$W/gcc-cross-amix/build"

# families-c.json's inputs: the five patchers it pins (and their helper), from this repository's history
mkdir -p "$W/inputs/patchers" "$W/inputs/control"
for p in patch_rth1_hook.py:90f4cdb patch_ttcompat_init.py:c2d7cad patch_pgrsv_sites.py:7905bd1 \
	patch_isp060_hook.py:148f785 patch_tcp_hiwat.py:c25d93d a4091_sd_rows.py:6e8f973; do
	git -C "$PORT_GIT" show ${p#*:}:src/${p%:*} > "$W/inputs/patchers/${p%:*}"
done
if [ -n "${CONTROL:-}" ]; then
	cp "$CONTROL" "$W/inputs/control/unix-060-fpe-r13-zz9000-c3-CARD1-ced0s1"
	CONTROL=$W/inputs/control/unix-060-fpe-r13-zz9000-c3-CARD1-ced0s1
fi
cp "$HERE/families-c.json" "$HERE/build-c.sh" "$HERE/post-c.sh" "$W/"

# the run: base, Model-B sysroot, kit, the chain, the post steps
export SOURCE_DATE_EPOCH=1793923200 AMIX_ALLOW_UNKNOWN_STOCK=1 GCA
cd "$W/port"
sh relink-040.sh > "$W/log/00-base.log" 2>&1; tail -n 1 "$W/log/00-base.log"
cp build/unix-040 build/b-new
sh src/mk_modelb_sysroot.sh > "$W/log/00-sysroot.log" 2>&1
(cd "$W/amix/kernel/dlm" && PATH=$CROSS/bin:$PATH make kit GCA="$GCA" PORT="$W/amix-040-060-port") > "$W/log/dlm-kit.log" 2>&1
W=$W PAULA=$PAULA sh "$W/build-c.sh" c > "$W/log/build-c.out" 2>&1
W=$W CONTROL=${CONTROL:-} bash "$W/post-c.sh" c > "$W/log/post-c.out" 2>&1
grep -q 'ALL GREEN' "$W/log/post-c.out" || echo "cut.sh: k0-gates not ALL GREEN (expected without CONTROL; see log/post-c.out)"

# the ufs module: fsobj-patch, the tail zeroing, the hole fix, the module build against this kit
M=$W/ufsmod; mkdir -p "$M"
python3 tools/fsobj-patch.py --stock "$W/stock/amix-2.1c/stand/unix" --base build/b-new \
	build/sysroot-modelb/usr/sys/fs/ufs/exp -o "$M/ufs-exp.k46" > "$M/fsobj-patch.log" 2>&1
sh tools/ufs-tailzero.sh "$M/ufs-exp.k46" "$M/ufs-exp-qz.k46" > "$M/ufs-tailzero.log" 2>&1
sh tools/ufs-holefix.sh "$M/ufs-exp-qz.k46" "$M/ufs-exp-hf.k46" > "$M/ufs-holefix.log" 2>&1
cp -r "$HERE/ufsmod" "$M/mod"
sed -i "s|^EXTRA = .*|EXTRA = $M/ufs-exp-hf.k46|" "$M/mod/Makefile"
(cd "$M/mod" && PATH=$CROSS/bin:$PATH make KIT="$W/amix/kernel/dlm/build/kit/k46" > make.log 2>&1)
grep -q 'modcheck: ufs: ok' "$M/mod/make.log" || { echo "cut.sh: the ufs module's modcheck failed"; exit 1; }
cp "$M/mod/build/k46/mod.d/ufs" "$W/out/c/ufs.mod"

cd "$W"
sha256sum out/c/unix out/c/kabi out/c/ufs.mod out/c/abi-k46.1.4.txt ufsmod/ufs-exp.k46 ufsmod/ufs-exp-qz.k46 \
	ufsmod/ufs-exp-hf.k46 port/build/b-new > "SHA256SUMS-$KB"
cat "SHA256SUMS-$KB"
[ -f "$HERE/SHA256SUMS-$KB" ] || { echo "cut.sh: no record to compare against"; exit 1; }
cmp -s "SHA256SUMS-$KB" "$HERE/SHA256SUMS-$KB" && echo "cut.sh: all eight sums equal the record" \
	|| { echo "cut.sh: the sums differ from the record"; exit 1; }
