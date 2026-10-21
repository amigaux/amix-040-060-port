#!/bin/sh
# test-tcp-hiwat.sh -- hermetic self-test of src/patch_tcp_hiwat.py (DRIVER-LINE-10).
# Assembles tiny ET_REL objects that carry a local `tcpm_info` (five stock module_info entries) and a
# local `tcplrinit` whose qi_minfo points at entry 3, and checks: stock -> 0x4000 in exactly that word,
# idempotent, --check exit codes, and refusals for a wrong old value, a qi_minfo that points elsewhere
# and a relocation on the word.  The stock kernel, when present, must read [stock] at .data 0xf9c8.
#
#     sh tools/test-tcp-hiwat.sh          # exits 0 if every case passes
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
W="$HERE/build/test-tcp-hiwat"; mkdir -p "$W"
P="$HERE/src/patch_tcp_hiwat.py"
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# gen HIWAT3 MINFO-ADDEND HIWAT3-WORD: the stock shape is gen 0x1000 0x48 '.long 0x1000'
gen() {
	printf '\t.data\nname:\t.asciz "tcp"\n\t.align 2\ntcpm_info:\n'
	for i in 0 1 2 3 4; do
		h='.long 0x1000'; [ $i = 3 ] && h="$3"
		printf '\t.word 0xca,0\n\t.long name\n\t.long 0,0x1000\n\t%s\n\t.long 0x400\n' "$h"
	done
	printf 'tcplrinit:\n\t.long 0,0,0,0,0\n\t.long tcpm_info+%s\n\t.long 0\n' "$2"
}
mk() { gen "$@" > "$W/t.s"; m68k-cbm-sysv4-gcc -m68040 -c "$W/t.s" -o "$W/t.o"; }
word() { m68k-linux-gnu-objcopy -O binary -j .data "$1" "$W/d.bin"; python3 -c "print(open('$W/d.bin','rb').read()[4+0x48+16:4+0x48+20].hex())"; }

mk 0x1000 0x48 '.long 0x1000'; cp "$W/t.o" "$W/stock.o"
if python3 "$P" --check "$W/t.o" >/dev/null 2>&1; then fail "--check on stock exits 1"; else pass "--check on stock exits 1"; fi
python3 "$P" "$W/t.o" | grep -q '\[ok\]' && pass "patches the stock object" || fail "patches the stock object"
python3 "$P" "$W/t.o" | grep -q '\[skip\]' && pass "a second run is a skip" || fail "a second run is a skip"
python3 "$P" --check "$W/t.o" >/dev/null 2>&1 && pass "--check on fixed exits 0" || fail "--check on fixed exits 0"
[ "$(word "$W/t.o")" = 00004000 ] && pass "entry 3 mi_hiwat is 0x4000" || fail "entry 3 mi_hiwat is 0x4000"
N=$(cmp -l "$W/stock.o" "$W/t.o" | wc -l)
[ "$N" = 1 ] && pass "exactly one byte changed" || fail "exactly one byte changed ($N)"

mk 0x1000 0x48 '.long 0x2000'
if python3 "$P" "$W/t.o" >/dev/null 2>&1; then fail "refuses a wrong old value (0x2000)"; else pass "refuses a wrong old value (0x2000)"; fi
if python3 "$P" --check "$W/t.o" >/dev/null 2>&1; then fail "--check refuses it too"; else pass "--check refuses it too"; fi
mk 0x1000 0x30 '.long 0x1000'
if python3 "$P" "$W/t.o" >/dev/null 2>&1; then fail "refuses a qi_minfo off entry 3"; else pass "refuses a qi_minfo off entry 3"; fi
mk 0x1000 0x48 '.long extsym'
if python3 "$P" "$W/t.o" >/dev/null 2>&1; then fail "refuses a relocation on the word"; else pass "refuses a relocation on the word"; fi

K="$AMIX_ROOT/stand/unix"
if [ -f "$K" ]; then
	python3 "$P" --check "$K" | grep -q '\[stock\] tcpm_info\[3\]\.mi_hiwat \.data 0xf9c8 = 0x1000' \
		&& pass "the stock kernel reads [stock] at .data 0xf9c8" || fail "the stock kernel reads [stock] at .data 0xf9c8"
else
	echo "SKIP the stock kernel ($K absent)"
fi

echo "$([ $fails = 0 ] && echo PASS || echo FAIL): $fails failing"
[ $fails = 0 ]
