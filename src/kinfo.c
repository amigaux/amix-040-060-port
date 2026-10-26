/*
 * kinfo.c -- /dev/kinfo, the kernel's read-only identity record (docs/contracts/KINFO.md).
 *
 * One record, built on the first open from the kernel's own copy of bootinfo (config() copies it
 * and nothing writes it afterwards): the CPU and line, the kabi tag, the build id, the loader's
 * AXL1 and RTH1 records as they arrived, the AutoConfig boards, sd's card table, the memory the
 * kernel runs on, the loader's bootdata block (where it bound the kernel, so a namelist can be
 * bound to it), and the loaded modules (none in a static kernel).  read(2) returns its
 * bytes from the file offset on, lseek(2) works as on any character device, write(2) is EPERM.
 *
 * The module kernel builds it with -DKINFO_DLM -DKINFO_KABI=\"k46.1.1\" (relink-040-kinfo.sh with
 * DLM=1): every read then refreshes the module list from the core's dlm_kinfo_list(), up
 * to KINFO_MAXMOD entries, with the length and the check to match (amix-dlm C2-1, stage-3 brief
 * step 8).  Without KINFO_DLM the object is the static kernel's, byte for byte.
 *
 * Linked by relink-040-kinfo.sh, which registers kinfoopen/close/read/write in cdevsw[53]
 * (src/patch_kinfo_cdevsw.py).  The node is `mknod /dev/kinfo c 53 0`, mode 0444.
 *
 * Kept free of division and of multiplication by a non-power of two, as src/rth1.c is.
 */
#include <sys/types.h>
#include <sys/errno.h>
#include <sys/uio.h>

#define KIF1_MAGIC	0x4B494631	/* "KIF1" */
#define KIF1_VERSION	3
#define KIF1_LENGTH	580		/* no modules */
#define KIF1_LINE	46

#define AXL1_MAGIC	0x41584C31	/* "AXL1" */
#define AXL1_LONGS	31		/* 124 bytes, all summed */
#define AXLF_SAFE	0x01
#define RTH1_MAGIC	0x52544831	/* "RTH1" */
#define RTH1_LONGS	14		/* 0x38 bytes */
#define RTH1_CHECKED	7		/* longs 0x00..0x18 sum to 0 */

#define BI_RTH1		0x678		/* loader reserved[0], kernel bootinfo+0x678 */
#define BI_AXL1		(BI_RTH1 + 0x38)
#define BI_BOOTDATA	0x650		/* entry, then text, rodata, data: vaddr, offset, size */
#define BOOTDATA_LEN	40
#define NAUTO		16
#define CD_SIZE		0x44		/* struct ConfigDev */
#define CD_PRODUCT	0x11		/* er_Product, a byte */
#define CD_MANUF	0x14		/* er_Manufacturer, a word */
#define CD_BOARDADDR	0x20
#define CD_BOARDSIZE	0x24
#ifndef SDCARDS
#define SDCARDS		2		/* sd.o's queue[]; -DSDCARDS=4 on a relink-040-sd4card.sh base */
#endif
#define SDQ_SIZE	16		/* f +0, c +4, a +8, hardware name +12 */

/* record offsets */
#define K_CHECK		8
#define K_CPU		12
#define K_LINE		16
#define K_ATTN		20
#define K_KABI		24
#define K_BUILD		48
#define K_FLAGS		80
#define K_AXL1		84
#define K_RTH1		208
#define K_NBOARD	264
#define K_BOARD		268
#define K_NCARD		460
#define K_CARD		464
#define K_FAST		528
#define K_CHIP		532
#define K_BOOTDATA	536
#define K_NMOD		576

#define KF_AXL1		0x1
#define KF_RTH1		0x2
#define KF_SAFE		0x4
#define KF_TVADDR	0x8		/* bootdata's text vaddr is not stext (.text+0 on this line) */
#define KC_MOBO		0x1

/* motherboard controllers: a zero manufacturer, so never a Zorro id */
#define MOBO_A3000WD	1
#define MOBO_GAYLE	2

extern unsigned char bootinfo[];
extern unsigned char sd_queue_tbl[];
extern char buildid[], stext[];
extern long cputype;
extern unsigned long chipmem, VSIZOFMEM;
extern int sdopen();
extern int uiomove();

#ifndef KINFO_KABI
#define KINFO_KABI	"static"
#endif
#ifdef KINFO_DLM
#define KINFO_MAXMOD	32
#define KINFO_RECMAX	(KIF1_LENGTH + 32 * KINFO_MAXMOD)
#define KINFO_LEN	kinfo_len
extern int dlm_kinfo_list();
static long kinfo_len = KIF1_LENGTH;
#else
#define KINFO_RECMAX	KIF1_LENGTH
#define KINFO_LEN	KIF1_LENGTH
#endif

/* The kabi tag; tools/kabi-sidecar.py reads it from the image for the sidecar's kabi=. */
char kinfo_kabi[24] = KINFO_KABI;

static unsigned long kinfo_rec[KINFO_RECMAX / 4] = { 0 };
static int kinfo_built = 0;

#define L(p, o)	(*(unsigned long *) ((unsigned char *) (p) + (o)))
#define W(p, o)	(*(unsigned short *) ((unsigned char *) (p) + (o)))

static int
kinfo_sum0(p, n)
unsigned long *p;
int n;
{
	unsigned long s = 0;

	while (n-- > 0)
		s += *p++;
	return s == 0;
}

static void
kinfo_copy(to, from, n)
unsigned char *to, *from;
int n;
{
	while (n-- > 0)
		*to++ = *from++;
}

static int
kinfo_streq(a, b)
char *a, *b;
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static void
kinfo_build()
{
	unsigned char *r = (unsigned char *) kinfo_rec, *cd, *q, *e;
	unsigned long *a = (unsigned long *) (bootinfo + BI_AXL1);
	unsigned long *h = (unsigned long *) (bootinfo + BI_RTH1);
	unsigned long flags = 0, s;
	int i, j, n;

	L(r, 0) = KIF1_MAGIC;
	L(r, 4) = (unsigned long) KIF1_VERSION << 16 | KIF1_LENGTH;
	L(r, K_CPU) = cputype;
	L(r, K_LINE) = KIF1_LINE;
	for (i = 0; i < 23 && kinfo_kabi[i]; i++)
		r[K_KABI + i] = kinfo_kabi[i];
	for (i = 0; i < 31 && buildid[1 + i]; i++)	/* " 68060-yymmdd-nn": drop the space */
		r[K_BUILD + i] = buildid[1 + i];

	if (a[0] == AXL1_MAGIC && (a[1] >> 16) == 1 && (a[1] & 0xFFFF) >= AXL1_LONGS * 4
	    && kinfo_sum0(a, AXL1_LONGS)) {
		kinfo_copy(r + K_AXL1, (unsigned char *) a, AXL1_LONGS * 4);
		L(r, K_ATTN) = a[6];
		flags |= KF_AXL1;
		if (a[9] & AXLF_SAFE)
			flags |= KF_SAFE;
	}
	if (h[0] == RTH1_MAGIC && (h[1] >> 16) == 1 && (h[1] & 0xFFFF) >= RTH1_LONGS * 4
	    && kinfo_sum0(h, RTH1_CHECKED)) {
		kinfo_copy(r + K_RTH1, (unsigned char *) h, RTH1_LONGS * 4);
		flags |= KF_RTH1;
	}
	kinfo_copy(r + K_BOOTDATA, bootinfo + BI_BOOTDATA, BOOTDATA_LEN);
	if (L(r, K_BOOTDATA + 4) != (unsigned long) stext)
		flags |= KF_TVADDR;
	L(r, K_FLAGS) = flags;

	/* the boards in the loader's order; an empty slot has no manufacturer and no base */
	n = 0;
	q = r + K_BOARD;
	for (i = 0, cd = bootinfo; i < NAUTO; i++, cd += CD_SIZE) {
		if (W(cd, CD_MANUF) == 0 && L(cd, CD_BOARDADDR) == 0)
			continue;
		W(q, 0) = W(cd, CD_MANUF);
		q[2] = cd[CD_PRODUCT];
		L(q, 4) = L(cd, CD_BOARDADDR);
		L(q, 8) = L(cd, CD_BOARDSIZE);
		q += 12;
		n++;
	}
	L(r, K_NBOARD) = n;

	/*
	 * sd's cards as its init() numbered them: queue[] slot k is card k, the c of a disk's cNdMsK
	 * being 8k + unit.  init() is lazy (it runs from the first sdopen), so run it now, as
	 * src/rth1.c does; it is guarded, so a later open finds it done.
	 */
	(void) sdopen(0);
	n = 0;
	q = r + K_CARD;
	for (i = 0, e = sd_queue_tbl; i < SDCARDS; i++, e += SDQ_SIZE) {
		unsigned long base = L(e, 8), id = 0, f = 0;

		if (L(e, 0) == 0)
			continue;
		for (j = 0, cd = bootinfo; j < NAUTO; j++, cd += CD_SIZE)
			if (L(cd, CD_BOARDADDR) == base && W(cd, CD_MANUF) != 0) {
				id = (unsigned long) W(cd, CD_MANUF) << 16 | (unsigned long) cd[CD_PRODUCT] << 8;
				break;
			}
		if (j == NAUTO) {
			/* no board at that address: a motherboard controller (or IDE's sort key) */
			char *nm = *(char **) (e + 12);

			base = 0;
			f = KC_MOBO;
			if (nm && kinfo_streq(nm, "A3000 Internal SCSI"))
				id = MOBO_A3000WD;
			else if (nm && kinfo_streq(nm, "A4000 IDE"))
				id = MOBO_GAYLE;
		}
		L(q, 0) = i;
		L(q, 4) = id;
		L(q, 8) = base;
		L(q, 12) = f;
		q += 16;
		n++;
	}
	L(r, K_NCARD) = n;

	L(r, K_FAST) = VSIZOFMEM;
	L(r, K_CHIP) = chipmem;
	L(r, K_NMOD) = 0;

	for (s = 0, i = 0; i < KIF1_LENGTH / 4; i++)
		s += kinfo_rec[i];
	L(r, K_CHECK) = -s;
	kinfo_built = 1;
}

#ifdef KINFO_DLM
/* The loaded modules into the record from KIF1_LENGTH on, and the count, length and check to match. */
static void
kinfo_mods()
{
	unsigned char *r = (unsigned char *) kinfo_rec;
	unsigned long s;
	int i, n;

	n = dlm_kinfo_list(r + KIF1_LENGTH, KINFO_MAXMOD);
	if (n < 0)
		n = 0;
	if (n > KINFO_MAXMOD)
		n = KINFO_MAXMOD;
	kinfo_len = KIF1_LENGTH + (n << 5);
	L(r, 4) = (unsigned long) KIF1_VERSION << 16 | kinfo_len;
	L(r, K_NMOD) = n;
	L(r, K_CHECK) = 0;
	for (s = 0, i = 0; i < kinfo_len >> 2; i++)
		s += kinfo_rec[i];
	L(r, K_CHECK) = -s;
}
#endif

int
kinfoopen(dp, oflags, otype, crp)
dev_t *dp;
int oflags, otype;
struct cred *crp;
{
	if ((*dp & 0x3FFFF) != 0)	/* minor 0 only */
		return ENXIO;
	if (!kinfo_built)
		kinfo_build();
	return 0;
}

int
kinfoclose(d, oflags, otype, crp)
dev_t d;
int oflags, otype;
struct cred *crp;
{
	return 0;
}

int
kinforead(d, uiop, crp)
dev_t d;
struct uio *uiop;
struct cred *crp;
{
	long off = uiop->uio_offset, n;

	if (off < 0)
		return EINVAL;
#ifdef KINFO_DLM
	kinfo_mods();
#endif
	if (off >= KINFO_LEN)
		return 0;
	n = KINFO_LEN - off;
	if (n > uiop->uio_resid)
		n = uiop->uio_resid;
	return uiomove((caddr_t) kinfo_rec + off, n, UIO_READ, uiop);
}

int
kinfowrite(d, uiop, crp)
dev_t d;
struct uio *uiop;
struct cred *crp;
{
	return EPERM;
}
