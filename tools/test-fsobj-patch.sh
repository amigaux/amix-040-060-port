#!/bin/sh
# test-fsobj-patch.sh -- tools/fsobj-patch.py on the stock ufs and s5 objects against a k46 base
# (amix-dlm S5-04): the sites and bytes it finds, the module-only sites, the patched objects'
# hashes, and each refusal.
#
#     FSOBJ_BASE=<b-new> FSOBJ_FS=<stock usr/sys/fs> sh tools/test-fsobj-patch.sh
#
# FSOBJ_BASE is relink-040.sh's base (b-new 284154a3 gives the numbers below); FSOBJ_FS holds the
# stock ufs/exp and s5/exp (a439e68f, 1c9cb634).  The stock kernel is config.sh's.  Unset: skipped.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
[ -n "$FSOBJ_BASE" ] && [ -n "$FSOBJ_FS" ] || { echo "test-fsobj-patch: FSOBJ_BASE/FSOBJ_FS unset, skipped"; exit 0; }
STOCK="$AMIX_ROOT/stand/unix"
T="$HERE/build/test-fsobj"; rm -rf "$T"; mkdir -p "$T"
P="python3 $HERE/tools/fsobj-patch.py --stock $STOCK"
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# the measured cut: sites applied, canaries, module-only sites, and the patched objects' sha256
# (with the module-only sites, and --static-only without them)
check() {	# fs sites canaries module-sites sha256 static-sha256
	$P --base "$FSOBJ_BASE" "$FSOBJ_FS/$1/exp" --triples > "$T/$1.triples" 2> "$T/$1.err" || { fail "$1: refused"; cat "$T/$1.err"; return; }
	n=$(grep -vc ' module:' "$T/$1.triples" || :); m=$(grep -c ' module:' "$T/$1.triples" || :)
	grep -q "$2 sites applied in the base ($2 bytes), 0 listed but not applied, $3 canaries hold; $4 module-only sites ($4 bytes)" "$T/$1.err" \
		&& [ "$n" = "$2" ] && [ "$m" = "$4" ] && pass "$1: $2 sites, $3 canaries, $4 module-only" || { fail "$1: $(cat "$T/$1.err")"; }
	for v in "$5:" "$6:--static-only"; do
		$P --base "$FSOBJ_BASE" "$FSOBJ_FS/$1/exp" -o "$T/$1.exp" ${v#*:} 2> /dev/null
		[ "$(sha256sum < "$T/$1.exp" | cut -c1-64)" = "${v%%:*}" ] && pass "$1: patched object $(echo ${v#*:} $(echo $v | cut -c1-8))" \
			|| fail "$1: patched object ${v#*:} $(sha256sum < "$T/$1.exp" | cut -c1-8), want $(echo $v | cut -c1-8)"
	done
}
check ufs 49 3 12 84316ffccc350fc83f4a215d7f52318327ae75e3211a5300a4603f8db97777c8 130b2def83eca2984316499913ae8342d76c1b0e908b45c220e797148cc4deaf
check s5 25 0 0 fc2bfe5a5850e7ea33addc3d906752bf297cdc7bdd5f0fc6327c6da4d8b3959d fc2bfe5a5850e7ea33addc3d906752bf297cdc7bdd5f0fc6327c6da4d8b3959d

# refusals: a copy of the base (or of the object) with one thing changed
mutate() {	# in out kind addr value
	python3 - "$@" <<'EOF'
import struct, sys
src, dst, kind, addr, val = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 16), int(sys.argv[5], 16)
b = bytearray(open(src, "rb").read())
so, se, sn, ss = struct.unpack(">I", b[32:36])[0], *struct.unpack(">HHH", b[46:52])
sh = [b[so + i * se:so + (i + 1) * se] for i in range(sn)]
st = struct.unpack(">I", sh[ss][16:20])[0]
def name(h): n = struct.unpack(">I", h[0:4])[0]; return b[st + n:b.index(b"\0", st + n)].decode()
sec = {name(h): struct.unpack(">II", h[16:24]) for h in sh}
if kind in ("rela", "reloff"):	# the addend (or the r_offset) of the .rela.text entry at r_offset addr
    o, n = sec[".rela.text"]
    i = next(o + k for k in range(0, n, 12) if struct.unpack(">I", b[o + k:o + k + 4])[0] == addr)
    if kind == "rela":
        b[i + 8:i + 12] = struct.pack(">i", struct.unpack(">i", b[i + 8:i + 12])[0] + val)
    else:
        b[i:i + 4] = struct.pack(">I", val)
else:			# one byte of .text or .data at addr
    b[sec[kind][0] + addr] = val
open(dst, "wb").write(b)
EOF
}
refuse() {	# label want-text fs base obj [stock]
	if python3 $HERE/tools/fsobj-patch.py --stock "${6:-$STOCK}" --base "$4" "$5" --triples > /dev/null 2> "$T/err"; then fail "$1: accepted"
	elif grep -q "$2" "$T/err"; then pass "$1: $(sed 's/^fsobj-patch: //' "$T/err" | cut -c1-90)"
	else fail "$1: $(cat "$T/err")"; fi
}
U="$FSOBJ_FS/ufs/exp"
mutate "$FSOBJ_BASE" "$T/b1" .text 0x76e60 0x4e && refuse "a byte no site lists" "no listed site accounts" ufs "$T/b1" "$U"
mutate "$FSOBJ_BASE" "$T/b2" .text 0x79d79 0x18 && refuse "a site's third value" "neither old" ufs "$T/b2" "$U"
mutate "$FSOBJ_BASE" "$T/b3" .data 0x8270 0x5a && refuse ".data changed" ".data 0x8260-0x864c differs" ufs "$T/b3" "$U"
mutate "$FSOBJ_BASE" "$T/b4" .text 0x79ec1 0x0c && refuse "a canary converted" "canary @0x79ec0" ufs "$T/b4" "$U"
R=$(m68k-linux-gnu-readelf -rW "$FSOBJ_BASE" | awk '/^Relocation section .\.rela\.text/{t=1;next} /^Relocation section/{t=0} t && $1 ~ /^0007[7-9a-f]/ {print $1; exit}')
mutate "$FSOBJ_BASE" "$T/b5" rela "$R" 0x4 && refuse "a relocation retargeted (0x$R)" "relocations are not the stock" ufs "$T/b5" "$U"
mutate "$U" "$T/o1" .text 0x10 0xff && refuse "an object not in the kernel" "matches 0 places" ufs "$FSOBJ_BASE" "$T/o1"
# the module-only table (ufs .text starts at 0x76e54 of the stock kernel's .text): the same change
# in the stock kernel, the base and the object, so the object is still found and the base still
# differs only at the scripts' sites
three() {	# kind obj-addr obj-value kernel-addr kernel-value
	mutate "$STOCK" "$T/u" "$1" "$4" "$5" && mutate "$FSOBJ_BASE" "$T/b" "$1" "$4" "$5" && mutate "$U" "$T/o" "$1" "$2" "$3"
}
three .text 0xc273 0x0a 0x830c7 0x0a && refuse "a module-only site's old byte (ufs_addmap moveq #10)" \
	"the object has 720a, the table expects 720b" ufs "$T/b" "$T/o" "$T/u"
three reloff 0x38c6 0x388e 0x7a71a 0x7a6e2 && refuse "a module-only site in a relocated field (kmem_alloc's moved there)" \
	"overlaps the relocated field of kmem_alloc+0 @0x388e" ufs "$T/b" "$T/o" "$T/u"
[ $fails = 0 ] && echo "PASS: 0 failing" || { echo "FAIL: $fails failing"; exit 1; }
