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
 * A fifth controller drops the lowest-ranked one, with one console line naming it, and a controller
 * at a base that is a card already (a module for a board sd's table drives) is dropped likewise.
 *
 * Module controllers (C4-1 section 3): sdopen()'s call of init() goes to sd4_init(), which runs the
 * stock init() and then, once, takes the module core's pending registrations and places them by
 * their class beside the table's rows.  The take is a call of sd4_noclose(), which answers none;
 * on a module kernel whose core has sd_register, relink-040-dlm.sh retargets that one call to the
 * core's dlm_sd_close(), which hands over its table and closes registration.
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
extern void sd4_stock_init();		/* sd.o's static init() */
extern int sd4_noclose();		/* dlm_sd_close() on a module kernel with sd_register */

/* the core's struct dlm_sdreg (C4-1 section 3), one pending registration */
struct sd4reg {
	unsigned long	r_f;		/* queue function */
	unsigned long	r_c;		/* board index, handed back to it */
	unsigned long	r_base;		/* sdcardbase() */
	char		*r_name;	/* sdhardwarename() */
	unsigned long	r_rank;		/* class, 1-4 */
};

/* Initialised, so it is .data: the image has .text and .data only. */
unsigned char sd_queue_tbl[SD4CARDS * SDQ_SIZE] = { 0 };
unsigned long sd4_rank[SD4CARDS] = { 0 };
unsigned long sd4_closed = 0;		/* the module registrations have been taken */

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

/* one controller, its place by class r and then by base */
static void
sd4_place(f, c, a, name, r)
unsigned long f, c, a, r;
char *name;
{
	unsigned char *q;
	int k, j, b;

	/*
	 * One card per board: a controller at a base that is a card already (a root module for a board
	 * the kernel also drives from sd's own table) is dropped, and the card keeps its driver.
	 */
	for (k = 0; k < SD4CARDS; k++) {
		q = sd_queue_tbl + k * SDQ_SIZE;
		if (L(q, 0) != 0 && a != 0 && L(q, 8) == a) {
			printf("sd: %s at 0x%x is card %d (%s) already; dropped\n", name, (int) a, k,
			       *(char **) (q + 12));
			return;
		}
	}
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

/* insert(f, c, a, name) as sd's init() calls it: a row of the table, ranked by its product. */
void
sd4_insert(f, c, a, name)
unsigned long f, c, a;
char *name;
{
	sd4_place(f, c, a, name, sd4_class(f));
}

/* init() as sdopen() calls it: the table's controllers, then once the modules' (C4-1 3.1). */
void
sd4_init()
{
	struct sd4reg *t, *e;
	int n, i;

	sd4_stock_init();
	if (sd4_closed)
		return;
	sd4_closed = 1;
	n = sd4_noclose(&t);
	for (i = 0, e = t; i < n && i < SD4CARDS; i++, e++)
		sd4_place(e->r_f, e->r_c, e->r_base, e->r_name, e->r_rank);
}
