/*
 * test-kinfo-cards.c -- drive the real kinfo object (src/kinfo.c, cross-compiled as the pass compiles
 * it) through its sd card table on qemu-m68k (docs/contracts/KINFO.md, amix-dlm C2-1 section 2.1 and
 * C4-1 section 5.1).  The harness provides what the kernel would: bootinfo, sd's queue table,
 * the build id, sdopen() and uiomove(), which hands back the record's address.  Run by
 * tools/test-kinfo.sh.
 */
#include <stdio.h>
#include <string.h>

/* what kinfo.o imports */
unsigned char bootinfo[0x780] __attribute__((aligned(4)));
unsigned char sd_queue_tbl[4 * 16] __attribute__((aligned(4)));
char buildid[] = " 68060-261027-99";
char stext[4];
long cputype = 60;
unsigned long chipmem = 0x00200000, VSIZOFMEM = 0x07f00000;
static unsigned char *rec;

int sdopen(int d) { return 0; }

/* the AMIX struct uio: uio_offset at 8, uio_resid at 20, 24 bytes */
struct uio { long iov, iovcnt, uio_offset, segflg_fmode, limit, uio_resid; };

int uiomove(void *addr, long n, int rw, struct uio *u)
{
	rec = addr;
	return 0;
}

/* what kinfo.o exports */
extern int kinfoopen(unsigned long *dp, int oflags, int otype, void *crp);
extern int kinforead(unsigned long d, struct uio *u, void *crp);

#define L(p, o)	(*(unsigned long *) ((unsigned char *) (p) + (o)))

static void configdev(int i, unsigned long base, unsigned short mfr, unsigned char prod)
{
	unsigned char *cd = bootinfo + i * 0x44;

	*(unsigned long *) (cd + 0x20) = base;
	*(unsigned short *) (cd + 0x14) = mfr;
	cd[0x11] = prod;
}

static void card(int k, unsigned long base, char *name)
{
	unsigned char *e = sd_queue_tbl + 16 * k;

	L(e, 0) = 0x1000 + k;		/* a queue function: any nonzero word */
	L(e, 8) = base;
	L(e, 12) = (unsigned long) name;
}

static int fails;

static void expect(int k, unsigned long id, unsigned long base, unsigned long flags)
{
	unsigned char *c = rec + 464 + 16 * k;
	int ok = L(c, 0) == (unsigned long) k && L(c, 4) == id && L(c, 8) == base && L(c, 12) == flags;

	printf("%s   card %d: id %08lx base %08lx flags %lx\n", ok ? "PASS" : "FAIL", k, L(c, 4), L(c, 8), L(c, 12));
	if (!ok) {
		printf("     want id %08lx base %08lx flags %lx\n", id, base, flags);
		fails++;
	}
}

static int build(void)
{
	unsigned long dev = 0;
	struct uio u = { 0, 0, 0, 0, 0, 2048 };

	if (kinfoopen(&dev, 0, 0, 0) != 0 || kinforead(0, &u, 0) != 0 || rec == 0) {
		printf("FAIL kinfo did not open and read\n");
		return 0;
	}
	return 1;
}

/* the record is built once per boot, so one set of cards per run: argv[1] picks it */
int main(int argc, char **argv)
{
	static char z3660[] = "Z3660 SCSI", a3000[] = "A3000 Internal SCSI", gayle[] = "A4000 IDE", other[] = "A4091",
		a4kt[] = "A4000T onboard SCSI";
	int n;

	if (argc > 1 && strcmp(argv[1], "a4000t") == 0) {
		/* the A4000T: its onboard 53C710 beside Gayle */
		card(0, 0x00dd0000, a4kt);
		card(1, 0xfffffff0, gayle);
		if (!build())
			return 1;
		n = 2;
		expect(0, 3, 0, 1);			/* a4000t-710 */
		expect(1, 2, 0, 1);			/* gayle */
	} else {
		/* the A4000T in 68030 mode with S5-15's second card: the Z3660 at its window, no board there */
		configdev(0, 0x40000000, 0xc0de, 1);	/* an A4092 */
		card(0, 0x10000000, z3660);
		card(1, 0x40000000, other);
		card(2, 0x00dd0000, a3000);
		card(3, 0xfffffff0, gayle);
		if (!build())
			return 1;
		n = 4;
		expect(0, 4, 0, 1);			/* z3660-window: motherboard id 4, never 0 */
		expect(1, 0xc0de0100, 0x40000000, 0);	/* an AutoConfig board: its id and base */
		expect(2, 1, 0, 1);			/* a3000-wd */
		expect(3, 2, 0, 1);			/* gayle */
	}
	printf("%s   %lu cards\n", L(rec, 460) == (unsigned long) n ? "PASS" : "FAIL", L(rec, 460));
	if (L(rec, 460) != (unsigned long) n)
		fails++;

	printf("%s: %d failing\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
