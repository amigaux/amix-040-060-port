/*
 * sd4card.c -- sd's controller table with four cards, in the rank order of amix-dlm C4-1
 * (2026-10-26).
 *
 * The stock sd.o keeps two controllers (SDCARDS 2) in a file-static queue[] of 16-byte records
 * (queue function +0, the board's autocon index +4, its base +8, the hardware name +12), sorted
 * by base, and drops a third.  relink-040-sd4card.sh points sd's accessors at sd_queue_tbl
 * below, raises sdopen()'s bound to card < 4, and retargets init()'s one call of insert() to
 * sd4_insert(); src/sd4card040.s does the same for the disk and tape tables.
 *
 * The order (C4-1 section 4): rank class, then base within a class, compacted over the
 * controllers present.  A row of sd's controller table has the class of its product:
 *   1 z3660  Z3660 SCSI (0x144B0001)
 *   2 zorro  A2090 (0x02020001), A2091 (0x02020003), A4091 (0x02020054), A4092 (0xC0DE0001)
 *   3 mobo   A3000 Internal SCSI (0x0202F003)
 *   4 ide    the Gayle IDE glue's row (0x1DE0A400)
 * init() hands insert() the row's queue function, not its product, so the class is found by
 * looking the queue function up in the table init() walks: the table and its bound are read
 * where init() itself reads them, from the operands of its `lea <table>,%a3` and `moveq #N,%d1`
 * (sd4_init_tbl and sd4_init_bound, exposed by the pass), so a pass that extends the table
 * before or after this one is followed.  A queue function no row names ranks as zorro.
 *
 * A fifth controller drops the lowest-ranked one, with one console line naming it.
 *
 * Kept free of division and of multiplication by a non-power of two, as src/rth1.c is.
 */

#define SD4CARDS	4
#define SDQ_SIZE	16		/* f +0, c +4, a +8, hardware name +12 */
#define ROW_SIZE	12		/* product, queue function, name */

#define RANK_Z3660	1
#define RANK_ZORRO	2
#define RANK_MOBO	3
#define RANK_IDE	4

#define L(p, o)		(*(unsigned long *) ((unsigned char *) (p) + (o)))

extern unsigned long sd4_init_tbl;	/* init()'s lea operand: the table's address */
extern unsigned char sd4_init_bound;	/* init()'s moveq operand: the last row's index */
extern int printf();

/* Initialised, so it is .data: the image has .text and .data only. */
unsigned char sd_queue_tbl[SD4CARDS * SDQ_SIZE] = { 0 };
unsigned long sd4_rank[SD4CARDS] = { 0 };

static unsigned long
sd4_class(f)
unsigned long f;
{
	unsigned char *row = (unsigned char *) sd4_init_tbl;
	int i;

	for (i = 0; i <= sd4_init_bound; i++, row += ROW_SIZE)
		if (L(row, 4) == f)
			switch (L(row, 0)) {
			case 0x144B0001:
				return RANK_Z3660;
			case 0x0202F003:
				return RANK_MOBO;
			case 0x1DE0A400:
				return RANK_IDE;
			default:
				return RANK_ZORRO;
			}
	return RANK_ZORRO;
}

/* insert(f, c, a, name) as sd's init() calls it: one controller, its place by rank. */
void
sd4_insert(f, c, a, name)
unsigned long f, c, a;
char *name;
{
	unsigned char *q;
	unsigned long r = sd4_class(f);
	int k, j, b;

	for (k = 0; k < SD4CARDS; k++) {
		q = sd_queue_tbl + k * SDQ_SIZE;
		if (L(q, 0) == 0 || r < sd4_rank[k] || (r == sd4_rank[k] && a < L(q, 8)))
			break;
	}
	if (k == SD4CARDS) {
		printf("sd: too many controllers, %s dropped\n", name);
		return;
	}
	q = sd_queue_tbl + (SD4CARDS - 1) * SDQ_SIZE;
	if (L(q, 0) != 0)
		printf("sd: too many controllers, %s dropped\n", *(char **) (q + 12));
	for (j = SD4CARDS - 1; j > k; j--) {
		for (q = sd_queue_tbl + j * SDQ_SIZE, b = 0; b < SDQ_SIZE; b += 4)
			L(q, b) = L(q - SDQ_SIZE, b);
		sd4_rank[j] = sd4_rank[j - 1];
	}
	q = sd_queue_tbl + k * SDQ_SIZE;
	L(q, 0) = f;
	L(q, 4) = c;
	L(q, 8) = a;
	L(q, 12) = (unsigned long) name;
	sd4_rank[k] = r;
}
