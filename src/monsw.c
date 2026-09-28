/*
 * monsw.c -- the monitor switch, card-independent: /dev/monsw and the kernel API card drivers
 * call (P-8, 2026-09-28).  sys/monsw.h has the value's meanings and where it comes from.
 *
 * Linked by relink-040-monsw.sh: a free cdevsw row for open/close/ioctl and monswinit() from
 * the parinit hook.  Everything here is initialised data, so a card driver may register
 * before monswinit() has run -- the io_init[] order is not this file's to choose.
 *
 * The line.  CIA-B's PRA/DDRA at their fixed addresses, reached through the kernel's
 * transparent translation (cache-inhibited, as the serial driver reaches the same port).  Only
 * the enabled bits are written: the port also carries the serial RTS/DTR and the parallel
 * status lines.  Latch the level first, then make the bit an output, so the line never
 * shows a stale level -- AmigaOS P96's SetSwitch does the same.  The read-modify-write runs at
 * IPL 4, the level the serial driver's own writes to the port run at.
 *
 * Nothing drives the line at boot: the state starts as "none" and the first monsw_set()
 * decides it.
 */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/errno.h>
#include <sys/cred.h>
#include <sys/ddi.h>
#include <sys/monsw.h>

#define MONSW_PRA       0xbfd000L
#define MONSW_DDRA      0xbfd200L
#define MONSW_PRA_CTS   0x10
#define MONSW_PRA_SEL   0x04
#define MONSW_NCARD     4

/*
 * IPL 4 around the read-modify-write.  Written out as __asm__ __volatile__ rather than taken
 * from sys/inline.h: the kernel is compiled -traditional, where a plain `volatile` asm can be
 * dropped as dead (T-9).  The relink pass checks that both SR writes are in the object.
 */
#define MONSW_SPLTTY(s) __asm__ __volatile__("mov.w %%sr,%0;mov.w &0x2400,%%sr" : "=d"(s))
#define MONSW_SPLX(s)   __asm__ __volatile__("mov.w %0,%%sr" : : "d"(s))

extern int printf();
extern int copyout();

int monsw_config = -1;                  /* patchable; >= 0 forces the value */

static int monsw_setval = -1;           /* from MONSWIOC_SETCFG */
static int monsw_seed = -1;             /* from the first card that offered one */
static int monsw_cfg = 0;               /* in effect */
static int monsw_src = MONSW_SRC_NONE;
static int monsw_state = -1;            /* last requested: 1 RTG, 0 native, -1 none */
static int monsw_isopen = 0;
static int monsw_want = 0;              /* a /dev/monsw holder asked for RTG */
static int monsw_said = 0;              /* invalid values already reported, by source */
static char *monsw_card[MONSW_NCARD];

static int
monsw_valid(v, src)
int v;
int src;
{
	if ((v & ~MONSW_VALID) == 0)
		return v;
	if (!(monsw_said & (1 << src))) {
		monsw_said |= 1 << src;
		printf("monsw: value 0x%x is not a 1/2/16/32 bit sum; taken as 0\n", v);
	}
	return 0;
}

/* Put the enabled line(s) of cfg to rtg.  The caller holds IPL 4. */
static void
monsw_drive(cfg, rtg)
int cfg;
int rtg;
{
	volatile unsigned char *pra = (volatile unsigned char *)MONSW_PRA;
	volatile unsigned char *ddra = (volatile unsigned char *)MONSW_DDRA;
	unsigned char mask, set, v;

	mask = 0;
	set = 0;
	if (cfg & MONSW_CTS) {
		mask |= MONSW_PRA_CTS;
		if ((cfg & MONSW_CTSLVL) ? !rtg : rtg)
			set |= MONSW_PRA_CTS;
	}
	if (cfg & MONSW_SEL) {
		mask |= MONSW_PRA_SEL;
		if ((cfg & MONSW_SELLVL) ? !rtg : rtg)
			set |= MONSW_PRA_SEL;
	}
	if (mask == 0)
		return;
	v = *pra;
	*pra = (v & ~mask) | set;       /* latch the level first ... */
	*ddra |= mask;                  /* ... then drive it */
}

/*
 * Recompute the value in effect after one of its sources changed.  A value that changes while
 * the state is RTG returns the old lines to native before the new ones take the state.
 */
static void
monsw_update()
{
	int cfg, src, s;

	if (monsw_config >= 0) {
		cfg = monsw_valid(monsw_config, MONSW_SRC_PATCH);
		src = MONSW_SRC_PATCH;
	} else if (monsw_setval >= 0) {
		cfg = monsw_setval;
		src = MONSW_SRC_SET;
	} else if (monsw_seed >= 0) {
		cfg = monsw_seed;
		src = MONSW_SRC_SEED;
	} else {
		cfg = 0;
		src = MONSW_SRC_NONE;
	}
	monsw_src = src;
	if (cfg == monsw_cfg)
		return;
	MONSW_SPLTTY(s);
	if (monsw_state == 1)
		monsw_drive(monsw_cfg, 0);
	monsw_cfg = cfg;
	if (monsw_state >= 0)
		monsw_drive(monsw_cfg, monsw_state);
	MONSW_SPLX(s);
}

void
monsw_set(rtg)
int rtg;
{
	int s;

	rtg = rtg ? 1 : 0;
	MONSW_SPLTTY(s);
	if (monsw_state != rtg) {
		monsw_state = rtg;
		monsw_drive(monsw_cfg, rtg);
	}
	MONSW_SPLX(s);
}

int
monsw_register(name, seed)
char *name;
int seed;
{
	int h;

	for (h = 0; h < MONSW_NCARD; h++)
		if (monsw_card[h] == 0)
			break;
	if (h == MONSW_NCARD) {
		printf("monsw: no slot for %s\n", name);
		return -1;
	}
	monsw_card[h] = name ? name : "card";
	if (seed >= 0 && monsw_seed < 0) {
		monsw_seed = monsw_valid(seed, MONSW_SRC_SEED);
		monsw_update();
	}
	printf("monsw: %s registered, seed %d; switch value %d\n", monsw_card[h], seed, monsw_cfg);
	return h;
}

void
monsw_unregister(h)
int h;
{
	if (h >= 0 && h < MONSW_NCARD)
		monsw_card[h] = 0;
}

/* A registered card's device had its last close: native, unless a holder wants RTG. */
void
monsw_lastclose(h)
int h;
{
	if (h < 0 || h >= MONSW_NCARD || monsw_card[h] == 0)
		return;
	if (!(monsw_isopen && monsw_want))
		monsw_set(0);
}

void
monswinit()
{
	monsw_update();
	if (monsw_src == MONSW_SRC_PATCH)
		printf("monsw: switch value %d (patched)\n", monsw_cfg);
}

/*ARGSUSED*/
int
monswopen(dp, oflags, otype, crp)
dev_t *dp;
int oflags, otype;
struct cred *crp;
{
	monsw_isopen = 1;
	return 0;
}

/*
 * Called on the last close only, including the close of a holder that died or was killed:
 * if a holder asked for RTG, the switch goes native.  A holder that only asked GETCFG leaves
 * the line alone -- a status query must not take the screen from a card driver that set RTG.
 */
/*ARGSUSED*/
int
monswclose(d, oflags, otype, crp)
dev_t d;
int oflags, otype;
struct cred *crp;
{
	monsw_isopen = 0;
	if (monsw_want) {
		monsw_want = 0;
		monsw_set(0);
	}
	return 0;
}

/*ARGSUSED*/
int
monswioctl(d, req, a, fmode, crp, rvp)
dev_t d;
int req, a, fmode;
struct cred *crp;
int *rvp;
{
	struct monsw_info mi;
	int h, e;

	switch (req) {
	case MONSWIOC_RTG:
		monsw_want = 1;
		monsw_set(1);
		return 0;
	case MONSWIOC_NATIVE:
		monsw_want = 0;
		monsw_set(0);
		return 0;
	case MONSWIOC_GETCFG:
		mi.mi_config = monsw_cfg;
		mi.mi_source = monsw_src;
		mi.mi_state = monsw_state;
		mi.mi_holder = monsw_want;
		mi.mi_ncards = 0;
		for (h = 0; h < MONSW_NCARD; h++)
			if (monsw_card[h])
				mi.mi_ncards++;
		if (copyout((caddr_t)&mi, (caddr_t)a, sizeof mi))
			return EFAULT;
		return 0;
	case MONSWIOC_SETCFG:
		if ((e = drv_priv(crp)) != 0)
			return e;
		if (monsw_config >= 0)
			return EBUSY;
		if (a < -1 || (a >= 0 && (a & ~MONSW_VALID)))
			return EINVAL;
		monsw_setval = a;
		monsw_update();
		return 0;
	}
	return EINVAL;
}
