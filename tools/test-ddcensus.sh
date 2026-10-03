#!/bin/sh
# test-ddcensus.sh -- run the diagnostic page-crossing census (src/ddcensus040.s) on qemu-m68k
# against a model of vtop, through a stub that calls it as dd's startio does (tools/test-ddcensus-call.S).
#
#     sh tools/test-ddcensus.sh          # exits 0 if every case passes
#
# Needs the AMIX cross assembler (config.sh), m68k-linux-gnu-gcc and qemu-m68k.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
for t in m68k-cbm-sysv4-gcc m68k-linux-gnu-gcc qemu-m68k; do
	command -v "$t" >/dev/null 2>&1 || { echo "[FAIL] $t not found"; exit 2; }
done
mkdir -p "$HERE/build"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/ddcensus040.s" -o "$HERE/build/ddcensus040-host.o"
m68k-linux-gnu-gcc -c "$HERE/tools/test-ddcensus-call.S" -o "$HERE/build/test-ddcensus-call.o"
m68k-linux-gnu-gcc -static -O1 -Wall -Werror "$HERE/tools/test-ddcensus.c" \
	"$HERE/build/test-ddcensus-call.o" "$HERE/build/ddcensus040-host.o" -o "$HERE/build/test-ddcensus"
qemu-m68k "$HERE/build/test-ddcensus"
