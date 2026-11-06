#!/usr/bin/env python3
# test-ddeof.py -- ISSUE-121's selftest: run a kernel image's own ddread and ddwrite bytes on qemu-m68k,
# stock and with src/patch_ddeof.py's 14 bytes, against stub sddevsize/uiophysio/breakup.
#
#     python3 tools/test-ddeof.py [KERNEL]      (default build/unix-040; patched or not, either works)
#
# The two functions are copied out of KERNEL with their eight R_68K_32 fields pointed at the stubs,
# once as stock (patch_ddeof.unpatch_buf) and once patched (patch_ddeof.patch_buf), and called through
# a shim that loads %d2-%d7/%a2-%a5 with markers and records them after the call.  Each case sets the
# slice size and the uio's offset and residue:
#   - patched: inside the slice uiophysio gets the stock arguments (the residue clamped at the end);
#     at the end 0 and no call; past the end ENXIO and no call (also offsets at and above 2^31);
#     a slice above 2 GiB with an offset above 2^31 inside it is still served (the compare is unsigned);
#   - stock: the same, except that past the end it calls uiophysio anyway (the bug): with a negative
#     residue, or unclamped where offset + residue wraps past 2^32.
# The callee-saved registers must come back unchanged in every case.  Exit 0 only if all hold.
# Needs m68k-linux-gnu-gcc, m68k-linux-gnu-objdump and qemu-m68k.
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("patch_ddeof", os.path.join(HERE, "src", "patch_ddeof.py"))
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)

STUB = {"sddevsize": "stub_sddevsize", "uiophysio": "stub_uiophysio", "breakup": "stub_breakup"}

HARNESS = r"""
#include <stdio.h>
extern long call_dd(void *fn, long dev, long *uio, unsigned long *regs);
extern char ddread_stock[], ddwrite_stock[], ddread_fix[], ddwrite_fix[];
static unsigned long g_size; static int g_calls;
static long g_strat, g_bp, g_dev, g_rw, g_resid; static long *g_uio;
long stub_sddevsize(long dev) { (void)dev; return (long)g_size; }
long stub_breakup(void) { return 0; }
long stub_uiophysio(long strat, long bp, long dev, long rw, long *uio)
{ g_calls++; g_strat = strat; g_bp = bp; g_dev = dev; g_rw = rw; g_uio = uio; g_resid = uio[5]; return 0x77; }
static const unsigned long mark[10] = { 0xd2d2d2d2, 0xd3d3d3d3, 0xd4d4d4d4, 0xd5d5d5d5, 0xd6d6d6d6,
					0xd7d7d7d7, 0xa2a2a2a2, 0xa3a3a3a3, 0xa4a4a4a4, 0xa5a5a5a5 };
/* size in sectors, offset, residue; then the expected result: ret, call?, the residue uiophysio saw */
struct c { unsigned long size, off; long resid; int past; };
static const struct c cases[] = {
	{ 131072, 0, 512, 0 },                     /* inside a 64 MiB slice */
	{ 131072, 0x3fffe00, 1024, 0 },            /* the last sector, the residue clamped to 512 */
	{ 131072, 0x4000000, 512, 0 },             /* at the end: 0 */
	{ 131072, 0x4000200, 512, 1 },             /* one sector past the end */
	{ 131072, 0x8000000, 512, 1 },             /* 64 MiB past */
	{ 131072, 0x80000000, 512, 1 },            /* 2^31 */
	{ 131072, 0xfffffe00, 512, 1 },            /* the top */
	{ 6000000, 0x90000000, 4096, 0 },          /* a 2.86 GiB slice, inside above 2^31 */
	{ 6000000, 0xb71afe00, 4096, 0 },          /* its last sector, clamped */
	{ 6000000, 0xb71b0000, 4096, 0 },          /* its end */
	{ 6000000, 0xb71b0200, 4096, 1 },          /* past it */
};
int main(void)
{
	struct { const char *n; char *f; long rw; int fix; } fn[] = {
		{ "ddread  stock", ddread_stock, 1, 0 }, { "ddwrite stock", ddwrite_stock, 0, 0 },
		{ "ddread  fix  ", ddread_fix, 1, 1 },   { "ddwrite fix  ", ddwrite_fix, 0, 1 } };
	int bad = 0, bugs = 0;
	for (unsigned i = 0; i < 4; i++)
		for (unsigned k = 0; k < sizeof cases / sizeof cases[0]; k++) {
			const struct c *c = &cases[k];
			long uio[8] = { 0 }; unsigned long regs[10]; int ok = 1;
			unsigned long end = c->size * 512;
			uio[2] = (long)c->off; uio[5] = c->resid;
			g_size = c->size; g_calls = 0; g_resid = 0x5a5a5a5a;
			long r = call_dd(fn[i].f, 0x123456, uio, regs);
			for (int j = 0; j < 10; j++) if (regs[j] != mark[j]) ok = 0;
			if (c->off == end) {
				if (r != 0 || g_calls) ok = 0;
			} else if (!c->past) {
				long want = c->off + c->resid > end ? (long)(end - c->off) : c->resid;
				if (r != 0x77 || g_calls != 1 || g_resid != want || g_strat != (long)stub_breakup
				    || g_bp != 0 || g_dev != 0x123456 || g_rw != fn[i].rw || g_uio != uio) ok = 0;
			} else if (fn[i].fix) {
				if (r != 6 || g_calls) ok = 0;
			} else {   /* stock past the end: the bug, a transfer is started anyway (the residue
				    * negative, or unclamped where offset + residue wraps past 2^32) */
				long want = c->off + c->resid > end ? (long)(end - c->off) : c->resid;
				if (r == 0x77 && g_calls == 1 && g_resid == want) bugs++;
				else ok = 0;
			}
			printf("%s size %8lu off 0x%08lx resid %5ld -> ret %3ld calls %d resid seen %ld %s\n",
			       fn[i].n, c->size, c->off, c->resid, r, g_calls, g_calls ? g_resid : 0L, ok ? "ok" : "WRONG");
			bad += !ok;
		}
	printf("stock past-the-end transfers started: %d (want 10)\n", bugs);
	if (bugs != 10) bad++;
	printf(bad ? "FAIL: %d\n" : "PASS\n", bad);
	return bad != 0;
}
"""

SHIM = r"""
	.text
	.globl	call_dd
| long call_dd(void *fn, long dev, long *uio, unsigned long *regs)
call_dd:
	linkw	%fp,#0
	moveml	%d2-%d7/%a2-%a5,%sp@-
	movel	#0xd2d2d2d2,%d2
	movel	#0xd3d3d3d3,%d3
	movel	#0xd4d4d4d4,%d4
	movel	#0xd5d5d5d5,%d5
	movel	#0xd6d6d6d6,%d6
	movel	#0xd7d7d7d7,%d7
	movel	#0xa2a2a2a2,%a2
	movel	#0xa3a3a3a3,%a3
	movel	#0xa4a4a4a4,%a4
	movel	#0xa5a5a5a5,%a5
	clrl	%sp@-
	movel	%fp@(16),%sp@-
	movel	%fp@(12),%sp@-
	moveal	%fp@(8),%a0
	jsr	%a0@
	lea	%sp@(12),%sp
	moveal	%fp@(20),%a1
	moveml	%d2-%d7/%a2-%a5,%a1@
	moveml	%fp@(-40),%d2-%d7/%a2-%a5
	unlk	%fp
	rts
"""


def emit(b, elf, name, label):
    """The function's bytes as .S, its relocated fields as .long <stub>."""
    addr, whole, relocs, _, _ = P.FUNCS[name]
    n = len(bytes.fromhex(whole))
    out = ["\t.globl\t%s" % label, "\t.even", "%s:" % label]
    o = 0
    while o < n:
        r = elf.rela.get(addr + o)
        if r:
            out.append("\t.long\t%s" % STUB[r[1]])
            o += 4
        else:
            out.append("\t.byte\t0x%02x" % b[elf.text + addr + o])
            o += 1
    return out


def main():
    img = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "build", "unix-040")
    W = os.path.join(HERE, "build", "ddeof-test")
    os.makedirs(W, exist_ok=True)
    src = open(img, "rb").read()
    stock, fix = bytearray(src), bytearray(src)
    P.unpatch_buf(stock)
    P.patch_buf(fix)
    lines = ["\t.text"]
    for variant, b in (("stock", stock), ("fix", fix)):
        elf = P.Elf(b)
        for name in P.FUNCS:
            lines += emit(b, elf, name, "%s_%s" % (name, variant))
    open(os.path.join(W, "funcs.S"), "w").write("\n".join(lines) + "\n")
    open(os.path.join(W, "shim.S"), "w").write(SHIM)
    open(os.path.join(W, "harness.c"), "w").write(HARNESS)
    for s in ("funcs.S", "shim.S"):
        subprocess.check_call(["m68k-linux-gnu-gcc", "-c", os.path.join(W, s), "-o", os.path.join(W, s[:-2] + ".o")])
    dis = subprocess.check_output(["m68k-linux-gnu-objdump", "-d", os.path.join(W, "funcs.o")], text=True)
    open(os.path.join(W, "funcs.lst"), "w").write(dis)
    subprocess.check_call(["m68k-linux-gnu-gcc", "-static", "-O1", "-Wall", "-Werror",
                           os.path.join(W, "harness.c"), os.path.join(W, "funcs.o"), os.path.join(W, "shim.o"),
                           "-o", os.path.join(W, "test-ddeof")])
    r = subprocess.run(["qemu-m68k", os.path.join(W, "test-ddeof")])
    print("[%s] test-ddeof on %s" % ("OK" if r.returncode == 0 else "FAIL", img))
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
