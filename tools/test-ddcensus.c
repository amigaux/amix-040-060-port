/*
 * test-ddcensus.c -- run src/ddcensus040.s (the diagnostic page-crossing census at dd's startio)
 * on qemu-m68k against a model of vtop: identity below 0x40000000, a table of kvseg pages above
 * it, some contiguous and some not.  Driven by tools/test-ddcensus.sh.
 */
#include <stdio.h>
#include <string.h>

extern long	dcn_magic, dcn_on, dcn_n, dcn_cross_id, dcn_cross_kv, dcn_kv_scat, dcn_ring_i;
extern long	dcn_ring[16][8];
extern long	call_census(long va, long proc, void *bp, long block);

static int	fails, nvtop;

/* kvseg model: virtual page -> frame */
static struct { unsigned long vp, fr; } kv[] = {
	{ 0x40010000, 0x08100000 }, { 0x40011000, 0x08101000 },	/* contiguous pair */
	{ 0x40020000, 0x08200000 }, { 0x40021000, 0x08377000 },	/* scattered pair  */
};

long
vtop(long va, long proc)
{
	unsigned long v = (unsigned long)va, i;

	(void)proc;
	nvtop++;
	if (v < 0x40000000UL)
		return (long)v;
	for (i = 0; i < sizeof kv / sizeof kv[0]; i++)
		if (kv[i].vp == (v & ~0xfffUL))
			return (long)(kv[i].fr | (v & 0xfffUL));
	return 0x7ffff000L;		/* unmapped: a recognisable value */
}

static unsigned char	bp[0x60];

static void
mkbuf(long len, long edev, int reading)
{
	memset(bp, 0, sizeof bp);
	bp[0x20] = len >> 24; bp[0x21] = len >> 16; bp[0x22] = len >> 8; bp[0x23] = len;
	bp[0x5c] = edev >> 24; bp[0x5d] = edev >> 16; bp[0x5e] = edev >> 8; bp[0x5f] = edev;
	bp[3] = reading ? 1 : 0;
}

static void
check(const char *what, int ok)
{
	printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
	if (!ok)
		fails++;
}

int
main(void)
{
	long pa;
	int i;

	check("dcn_magic reads \"DCN!\"", (unsigned long)dcn_magic == 0x44434e21UL);

	mkbuf(1024, 0x00480016, 1);
	pa = call_census(0x40020c00, 7, bp, 50);
	check("a buffer ending exactly on a page boundary is not a crosser",
	      dcn_n == 1 && dcn_cross_kv == 0 && pa == 0x08200c00);
	dcn_n = 0;

	mkbuf(2048, 0x00480016, 1);
	pa = call_census(0x08001000, 0, bp, 100);
	check("identity, inside a page: counted, no crosser, pa == va",
	      dcn_n == 1 && dcn_cross_id == 0 && dcn_cross_kv == 0 && pa == 0x08001000);

	mkbuf(512, 0x00480016, 1);
	pa = call_census(0x08136e24, 0, bp, 1);
	check("identity crosser (getrdb's block at page offset 0xe24): cross_id, no ring",
	      dcn_cross_id == 1 && dcn_cross_kv == 0 && dcn_ring_i == 0 && pa == 0x08136e24);

	mkbuf(4096, 0x00480016, 0);
	nvtop = 0;
	pa = call_census(0x40010800, 7, bp, 200);
	check("kvseg crosser, contiguous frames: cross_kv, not scattered, ring entry, write",
	      dcn_cross_kv == 1 && dcn_kv_scat == 0 && dcn_ring_i == 1 && pa == 0x08100800 &&
	      nvtop == 2 && dcn_ring[0][1] == 0x40010800 && dcn_ring[0][2] == 0x08100800 &&
	      dcn_ring[0][3] == 0x08101000 && dcn_ring[0][4] == 4096 && dcn_ring[0][5] == 200 &&
	      dcn_ring[0][6] == 0x00480016 && dcn_ring[0][7] == 0);

	mkbuf(2048, 0x00480016, 1);		/* 0xc00 + 0x800 runs 0x400 into the next page */
	pa = call_census(0x40020c00, 7, bp, 300);
	check("kvseg crosser, scattered frames: kv_scat, flags read|scattered",
	      dcn_cross_kv == 2 && dcn_kv_scat == 1 && dcn_ring_i == 2 && pa == 0x08200c00 &&
	      dcn_ring[1][3] == 0x08377000 && dcn_ring[1][7] == 5 && dcn_ring[1][5] == 300);

	mkbuf(1024, 0x00480016, 1);
	pa = call_census(0x40010000, 7, bp, 400);
	check("kvseg inside a page: not a crosser", dcn_cross_kv == 2 && dcn_ring_i == 2 &&
	      pa == 0x08100000);

	mkbuf(4096, 0x00480016, 1);
	pa = call_census(0x40011000, 7, bp, 500);
	check("exactly one page from a page boundary: not a crosser", dcn_cross_kv == 2);

	dcn_on = 0;
	i = dcn_n;
	mkbuf(4096, 0x00480016, 1);
	pa = call_census(0x40020800, 7, bp, 600);
	check("dcn_on = 0: pass-through, nothing counted, pa unchanged",
	      dcn_n == i && dcn_cross_kv == 2 && pa == 0x08200800);
	dcn_on = 1;

	for (i = 0; i < 15; i++) {
		mkbuf(4096, 0, 0);
		call_census(0x40010800, 7, bp, 1000 + i);
	}
	check("the ring wraps at 16: slot 0 holds the 17th kvseg crosser",
	      dcn_ring_i == 17 && dcn_ring[0][5] == 1014 && dcn_ring[1][5] == 300);

	printf("%s: %d failing\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
