#!/bin/sh
# test-kinfo.sh -- host self-test of the /dev/kinfo tools (docs/contracts/KINFO.md).
# Compiles src/kinfo.c and checks its sections and its symbol sets; builds records in Python and
# checks that tools/kinfo-decode.py accepts a well-formed one, in binary and as `od -X` text, and
# refuses a bad check word, a wrong length, a flagged AXL1 that is not one and a zero text vaddr; runs
# the card table on qemu-m68k (tools/test-kinfo-cards.c); checks patch_kinfo_cdevsw.py --check on the base kernels in build/ when they are there.
#
#     sh tools/test-kinfo.sh          # exits 0 if every case passes
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
W="$HERE/build/test-kinfo"; mkdir -p "$W"
D="$HERE/tools/kinfo-decode.py"
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/kinfo.c" -o "$W/kinfo.o"
m68k-linux-gnu-readelf -SW "$W/kinfo.o" | grep -q '\.rodata' && fail "kinfo.o has no .rodata" || pass "kinfo.o has no .rodata"
U=$(m68k-linux-gnu-nm "$W/kinfo.o" | awk '$1=="U"{print $2}' | LC_ALL=C sort | tr '\n' ' ')
[ "$U" = "VSIZOFMEM bootinfo buildid chipmem cputype sd_queue_tbl sdopen stext uiomove " ] \
	&& pass "kinfo.o imports exactly its nine symbols" || fail "kinfo.o imports: $U"

python3 - "$W" <<'EOF'
import struct, sys
w = sys.argv[1]

def seal(b, n, at):
    struct.pack_into(">I", b, at, 0)
    struct.pack_into(">I", b, at, -sum(struct.unpack(">%dI" % n, bytes(b[:4 * n]))) & 0xFFFFFFFF)

r = bytearray(580)
r[0:4] = b"KIF1"
struct.pack_into(">IIII", r, 4, 3 << 16 | 580, 0, 60, 46)
r[24:30] = b"static"
r[48:63] = b"68060-261025-50"
struct.pack_into(">I", r, 80, 3)
a = bytearray(124); a[0:4] = b"AXL1"; struct.pack_into(">I", a, 4, 1 << 16 | 124); seal(a, 31, 8); r[84:208] = a
h = bytearray(56); h[0:4] = b"RTH1"; struct.pack_into(">IIII", h, 4, 1 << 16 | 56, 1, 6, 0); seal(h, 7, 24); r[208:264] = h
struct.pack_into(">I", r, 264, 1); struct.pack_into(">HBBII", r, 268, 0x144B, 1, 0, 0x40000000, 0x08000000)
struct.pack_into(">I", r, 460, 1); struct.pack_into(">IIII", r, 464, 0, 0x144B0100, 0x40000000, 0)
struct.pack_into(">II", r, 528, 0x00FFFFE0, 0x00200000)
struct.pack_into(">10I", r, 536, 0x07F00000, 0x07F00000, 0x34, 0x10B764, 0, 0, 0, 0x0800B764, 0x10B798, 0x7FD74)
seal(r, 145, 8)
open(w + "/good.bin", "wb").write(r)
with open(w + "/good.od", "w") as f:
    for o in range(0, 580, 16):
        f.write("%07o %s\n" % (o, " ".join("%08x" % v for v in struct.unpack(">%dI" % (min(16, 580 - o) // 4), r[o:o + 16]))))
b = bytearray(r); b[8] ^= 1; open(w + "/badsum.bin", "wb").write(b)
b = bytearray(r); struct.pack_into(">I", b, 4, 3 << 16 | 584); seal(b, 145, 8); open(w + "/badlen.bin", "wb").write(b)
b = bytearray(r); b[100] ^= 0xFF; seal(b, 145, 8); open(w + "/badaxl.bin", "wb").write(b)
b = bytearray(r); struct.pack_into(">I", b, 540, 0); seal(b, 145, 8); open(w + "/badtva.bin", "wb").write(b)
b = bytearray(r); struct.pack_into(">I", b, 80, 3 | 8); seal(b, 145, 8); open(w + "/flag8.bin", "wb").write(b)
v = bytearray(r[:540]); struct.pack_into(">II", v, 4, 2 << 16 | 540, 0); struct.pack_into(">I", v, 536, 0); seal(v, 135, 8)
open(w + "/v2.bin", "wb").write(v)
EOF
python3 "$D" "$W/good.bin" > "$W/good.txt" && pass "a well-formed record decodes OK" || fail "a well-formed record decodes OK"
python3 "$D" --od "$W/good.od" > /dev/null && pass "the same record as od -X text decodes OK" || fail "the same record as od -X text"
grep -q "card 0: zorro:144b:01 base 0x40000000" "$W/good.txt" && pass "the card row reads zorro:144b:01" || fail "the card row"
grep -q "bootdata: entry 0x07f00000 text 0x07f00000 +0x34 0x10b764" "$W/good.txt" && pass "version 3: the bootdata block decodes" || fail "the bootdata block"
python3 "$D" "$W/flag8.bin" | grep -q "TVADDR" && pass "flag 0x8 decodes as TVADDR" || fail "flag 0x8"
python3 "$D" "$W/v2.bin" > /dev/null && pass "a version 2 record still decodes OK" || fail "a version 2 record"
for c in badsum badlen badaxl badtva; do
	if python3 "$D" "$W/$c.bin" > /dev/null 2>&1; then fail "refuses $c"; else pass "refuses $c"; fi
done

# the sd card table, run on qemu-m68k: an AutoConfig board's id and base, the motherboard ids by
# controller name, and the Z3660 at its window as id 4 (tools/test-kinfo-cards.c; amix-dlm C4-1 5.1)
if command -v m68k-linux-gnu-gcc >/dev/null 2>&1 && command -v qemu-m68k >/dev/null 2>&1; then
	m68k-cbm-sysv4-gcc $CF -DSDCARDS=4 -c "$HERE/src/kinfo.c" -o "$W/kinfo-sd4.o"
	m68k-linux-gnu-gcc -static -O1 -Wall -Werror "$HERE/tools/test-kinfo-cards.c" "$W/kinfo-sd4.o" -o "$W/test-kinfo-cards"
	qemu-m68k "$W/test-kinfo-cards" > "$W/cards.txt" && pass "the card table (test-kinfo-cards.c)" \
		|| { cat "$W/cards.txt"; fail "the card table (test-kinfo-cards.c)"; }
	grep -q "PASS   card 0: id 00000004 base 00000000 flags 1" "$W/cards.txt" && pass "the Z3660 at its window is mobo id 4" \
		|| fail "the Z3660 at its window is mobo id 4"
else
	echo "SKIP the card table: no m68k-linux-gnu-gcc or qemu-m68k"
fi

for K in "$HERE"/build/unix-040-z-rth1*; do
	[ -f "$K" ] || continue
	RC=0; python3 "$HERE/src/patch_kinfo_cdevsw.py" --check "$K" > /dev/null 2>&1 || RC=$?
	case "$(m68k-linux-gnu-nm "$K" | grep -c ' T kinfoopen$')" in
	0) [ $RC = 1 ] && pass "cdevsw[53] free in $(basename "$K")" || fail "cdevsw[53] in $(basename "$K"): exit $RC" ;;
	*) [ $RC = 0 ] && pass "cdevsw[53] is kinfo's in $(basename "$K")" || fail "cdevsw[53] in $(basename "$K"): exit $RC" ;;
	esac
done

echo "$([ $fails = 0 ] && echo PASS || echo FAIL): $fails failing"
[ $fails = 0 ]
