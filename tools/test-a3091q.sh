#!/bin/sh
# test-a3091q.sh -- run the A3091 start-queue wrappers (src/a3091q040.s) on qemu-m68k against a
# host model of the queue (tools/test-a3091q.c), with the fix on and with it off.
#
#     sh tools/test-a3091q.sh          # exits 0 if every case passes
#
# WHY THIS FILE EXISTS
#
# The defect the wrappers guard needs a SCSI target that disconnects and reselects, and the
# emulator's WD33C93 never does, so no boot there reaches the code.  This links the same object
# relink-040-a3091q.sh links and drives the three entry points the way the retargeted call
# sites do.  Each scenario runs with a3q_on = 1, where it must show the fix, and with
# a3q_on = 0, where it must show the stock defect -- the control is what proves the test can
# fail.  What this cannot show is the kernel side: that the retargets landed on the right call
# sites (patch_a3091_queue.py asserts that) and that the stack shape at those sites is the one
# modelled here (the call shapes are in src/a3091q040.s).
#
# Needs the AMIX cross assembler (config.sh), m68k-linux-gnu-gcc and qemu-m68k.

set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
for t in m68k-cbm-sysv4-gcc m68k-linux-gnu-gcc qemu-m68k; do
	command -v "$t" >/dev/null 2>&1 || { echo "[FAIL] $t not found"; exit 2; }
done
mkdir -p "$HERE/build"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/a3091q040.s" -o "$HERE/build/a3091q040-host.o"
m68k-linux-gnu-gcc -static -O1 -Wall -Werror "$HERE/tools/test-a3091q.c" \
	"$HERE/build/a3091q040-host.o" -o "$HERE/build/test-a3091q"
qemu-m68k "$HERE/build/test-a3091q"
