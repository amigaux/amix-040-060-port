#!/bin/bash
# cut.sh OUT -- cut 68060-261031-52 (the k46 module kernel, kabi k46.1.3) into OUT: -51's recipe with this
# repository at fff9660, where FREEQ_GUARD=1 (ISSUE-109) joins KZERO=1 and UFS_TAILZERO=1 as a default.
# Inputs, by environment:
#   PORT_GIT     a clone of this repository that has fff9660 and the patcher revisions below (default: this one)
#   AMIX         an amix clone that has e45b061 (amix-dlm's history, kept by the move-in: the module core and kit)
#                and fce38f4 (kernel/k30/tools and contracts: sddevsize and W-D7 injectors, emit-family-chains, k0-gates)
#   PAULA        amix-paula with 62fdcab (the audio driver's three patchers)
#   GCA          gcc-cross-amix's build/ (env.sh; toolchain/gcc-cross-amix.pin, gcc 2.7.2.3 8949028)
#   AMIX_SYSTEM  amigaux/amix-system (kernels/2.1c/unix, the stock kernel the relinks check against)
#   NETBSD_SYSSRC  NetBSD 10.1's source/sets/syssrc.tgz (the FPSP; tools/netbsd-pin.sh checks its sha256)
#   CONTROL      optional: the frozen candidate-3 kernel (5aa7d732) emit and k0-gates compare against
# OUT gets the run root (port/ = git archive fff9660, the build tree; amix-040-060-port/ = a clone at fff9660;
# dlm-e45b061/; amix-kerntools/ = amix fce38f4's kernel/k30 tools and contracts; inputs/) and
# SHA256SUMS-68060-261031-52, which must equal this directory's.
set -eu
REV=fff9660 DLM_REV=e45b061 K30_REV=fce38f4 KB=68060-261031-52
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:?usage: cut.sh OUT}; PORT_GIT=${PORT_GIT:-$(git -C "$HERE" rev-parse --show-toplevel)}
: "${AMIX:?}" "${PAULA:?}" "${GCA:?}" "${AMIX_SYSTEM:?}" "${NETBSD_SYSSRC:?}"; [ -z "${KT:-}" ] || { echo "cut.sh: KT must be unset"; exit 2; }
mkdir -p "$W"; W=$(cd "$W" && pwd); [ -z "$(ls -A "$W")" ] || { echo "cut.sh: $W is not empty"; exit 2; }
. "$GCA/env.sh"; CROSS=$AMIX_CROSS_PREFIX
GNU=$(dirname "$(command -v m68k-linux-gnu-nm)")
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
mv "$W/port/src/stamp_buildid.py" "$W/port/src/stamp_buildid.real.py"
cp "$HERE/stamp_buildid.py" "$W/port/src/stamp_buildid.py"; cp "$HERE/blocks.py" "$W/port/tools/blocks.py"
mkdir -p "$W/port/build"; echo "261031 51" > "$W/port/build/.build-seq"

# the siblings the kit and the family tools find: the port clone, the dlm clone, the tools (in the directory
# kerntools' layout names), the toolchain
git clone -q "$PORT_GIT" "$W/amix-040-060-port"; git -C "$W/amix-040-060-port" checkout -q --detach $REV
cp "$W/port/config.sh" "$W/amix-040-060-port/config.sh"     # k0-gates runs its tools/status-facts.sh
git clone -q "$AMIX" "$W/dlm-$DLM_REV"; git -C "$W/dlm-$DLM_REV" checkout -q --detach $DLM_REV
mkdir -p "$W/amix-kerntools"; git -C "$AMIX" archive $K30_REV kernel/k30/tools kernel/k30/contracts | tar -x --strip-components=2 -C "$W/amix-kerntools"
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

# -51's run: base, Model-B sysroot, kit, the chain, the post steps
export SOURCE_DATE_EPOCH=1793404800 AMIX_ALLOW_UNKNOWN_STOCK=1 GCA
cd "$W/port"
sh relink-040.sh > "$W/log/00-base.log" 2>&1; tail -n 1 "$W/log/00-base.log"
cp build/unix-040 build/b-new
sh src/mk_modelb_sysroot.sh > "$W/log/00-sysroot.log" 2>&1
(cd "$W/dlm-$DLM_REV" && PATH=$CROSS/bin:$PATH make kit) > "$W/log/dlm-kit.log" 2>&1
W=$W PAULA=$PAULA sh "$W/build-c.sh" c > "$W/log/build-c.out" 2>&1
W=$W CONTROL=${CONTROL:-} bash "$W/post-c.sh" c > "$W/log/post-c.out" 2>&1
grep -q 'ALL GREEN' "$W/log/post-c.out" || echo "cut.sh: k0-gates not ALL GREEN (expected without CONTROL; see log/post-c.out)"

# the ufs module: fsobj-patch, the tail zeroing, the module build against this kit
M=$W/ufsmod; mkdir -p "$M"
python3 tools/fsobj-patch.py --stock "$W/stock/amix-2.1c/stand/unix" --base build/b-new \
	build/sysroot-modelb/usr/sys/fs/ufs/exp -o "$M/ufs-exp.k46" > "$M/fsobj-patch.log" 2>&1
sh tools/ufs-tailzero.sh "$M/ufs-exp.k46" "$M/ufs-exp-qz.k46" > "$M/ufs-tailzero.log" 2>&1
cp -r "$HERE/ufsmod" "$M/mod"
sed -i "s|^EXTRA = .*|EXTRA = $M/ufs-exp-qz.k46|" "$M/mod/Makefile"
(cd "$M/mod" && PATH=$CROSS/bin:$PATH make KIT="$W/dlm-$DLM_REV/build/kit/k46" > make.log 2>&1)
grep -q 'modcheck: ufs: ok' "$M/mod/make.log" || { echo "cut.sh: the ufs module's modcheck failed"; exit 1; }
cp "$M/mod/build/k46/mod.d/ufs" "$W/out/c/ufs.mod"

cd "$W"
sha256sum out/c/unix out/c/kabi out/c/ufs.mod out/c/abi-k46.1.3.txt ufsmod/ufs-exp.k46 ufsmod/ufs-exp-qz.k46 \
	port/build/b-new > "SHA256SUMS-$KB"
cat "SHA256SUMS-$KB"
cmp -s "SHA256SUMS-$KB" "$HERE/SHA256SUMS-$KB" && echo "cut.sh: all seven sums equal the record" \
	|| { echo "cut.sh: the sums differ from the record"; exit 1; }
