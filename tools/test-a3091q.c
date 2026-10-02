/*
 * test-a3091q.c -- run src/a3091q040.s, the A3091 start-queue wrappers, on qemu-m68k against a
 * host model of the queue they guard (2026-10-02).  Driven by tools/test-a3091q.sh.
 *
 * Why a host harness.  The defect needs a SCSI target to disconnect and reselect, and the
 * emulator's WD33C93 never does (src/a3091q040.s, COUNTERS), so a kernel boot there can show
 * that the wrappers are inert and nothing about whether they work.  This links the very object
 * the relink pass links and calls its three entry points the way the retargeted call sites do.
 *
 * The model.  The wrappers tail-jump to three kernel routines; here they are stand-ins that
 * keep the queue the way the stock driver does (append at the tail and clear the link; on an
 * empty queue start at once; pop the head only when idle) and record what they were asked to
 * do.  The model's own append calls the startany WRAPPER, because in the kernel the call
 * inside the stock append is one of the retargeted sites.
 *
 * Every scenario runs twice: a3q_on = 1 must show the fix, a3q_on = 0 must show the defect.
 * A scenario that passes both ways would be testing nothing.
 */
#include <stdio.h>

struct qunit {
	struct qunit	*next;		/* +0 */
	void		*comhead;	/* +4 */
	void		*comtail;	/* +8 */
	unsigned char	tc[4];		/* +0xc; 16 bytes, as in the binary */
};

struct qunit	*a3091_starthead, *a3091_starttail;
unsigned int	a3091_istate;		/* 0 = IDLE */

extern int	a3q_magic, a3q_on, a3q_dbl, a3q_unq, a3q_drop, a3q_walkcap;
extern void	a3091q_uqueue(struct qunit *);
extern void	a3091q_startany(void);
extern void	a3091q_resume(struct qunit *);

static struct qunit	u[8];
static int		cmd[8];			/* a non-null comhead to point at */
static struct qunit	*started[32];
static int		nstarted, nwild, nreconn;
static struct qunit	*reconn_arg;
static int		fails;

void
a3091_uqueue(struct qunit *up)
{
	up->next = 0;
	if (a3091_starthead == 0) {
		a3091_starthead = a3091_starttail = up;
		a3091q_startany();
		return;
	}
	a3091_starttail->next = up;
	a3091_starttail = up;
}

void
a3091_startany(void)
{
	struct qunit *up = a3091_starthead;

	if (a3091_istate != 0 || up == 0)
		return;
	a3091_starthead = up->next;
	if (up->comhead == 0)
		nwild++;		/* the stock body would build a command from a null comhead */
	started[nstarted++] = up;
	a3091_istate = 1;		/* STARTING */
}

void
dma_a3091_startdma_reconn(struct qunit *up)
{
	reconn_arg = up;
	nreconn++;
}

static void
reset(int on)
{
	int i;

	for (i = 0; i < 8; i++) {
		u[i].next = 0;
		u[i].comhead = u[i].comtail = &cmd[i];
	}
	a3091_starthead = a3091_starttail = 0;
	a3091_istate = 1;		/* busy: appends do not start anything unless a test says so */
	nstarted = nwild = nreconn = 0;
	reconn_arg = 0;
	a3q_on = on;
	a3q_dbl = a3q_unq = a3q_drop = a3q_walkcap = 0;
}

/* the queue as a string of unit numbers, "-" when empty, "!" after 9 links (a cycle) */
static const char *
queue(void)
{
	static char s[32];
	struct qunit *p = a3091_starthead;
	int n = 0;

	if (p == 0)
		return "-";
	while (p && n < 9) {
		s[n++] = '0' + (int)(p - u);
		p = p->next;
	}
	if (p)
		s[n++] = '!';
	s[n] = 0;
	return s;
}

static void
check(int on, const char *what, int ok)
{
	printf("  [%s] a3q_on=%d  %s\n", ok ? "ok" : "FAIL", on, what);
	if (!ok)
		fails++;
}

#define	STR_EQ(a, b)	(__builtin_strcmp((a), (b)) == 0)

/* (a) re-queueing a unit that is already linked */
static void
t_double_link(int on)
{
	reset(on);
	a3091q_uqueue(&u[1]);
	a3091q_uqueue(&u[2]);
	a3091q_uqueue(&u[3]);
	a3091q_uqueue(&u[1]);			/* 1 is already the head */
	if (on)
		check(on, "re-queue of a linked unit refused, queue 123 intact",
		      STR_EQ(queue(), "123") && a3q_dbl == 1 && a3091_starttail == &u[3]);
	else
		check(on, "control: re-queue cuts the queue at the unit (stock defect)",
		      !STR_EQ(queue(), "123") && a3q_dbl == 0);
}

/* (c) the reselect path resumes a unit that is still linked */
static void
t_resume_unlink(int on)
{
	reset(on);
	a3091q_uqueue(&u[4]);
	a3091q_uqueue(&u[5]);
	a3091q_uqueue(&u[6]);
	a3091q_resume(&u[5]);			/* middle */
	if (on) {
		check(on, "resume unlinks a middle unit: 46", STR_EQ(queue(), "46") && a3q_unq == 1);
		a3091q_resume(&u[6]);		/* tail */
		check(on, "resume unlinks the tail and moves starttail back",
		      STR_EQ(queue(), "4") && a3091_starttail == &u[4] && a3q_unq == 2);
		a3091q_resume(&u[4]);		/* the only one */
		check(on, "resume unlinks the last unit: queue empty", STR_EQ(queue(), "-") && a3q_unq == 3);
		a3091q_resume(&u[7]);		/* never linked: the normal shape */
		check(on, "resume of an unlinked unit changes nothing", STR_EQ(queue(), "-") && a3q_unq == 3);
	} else
		check(on, "control: resume leaves the unit linked (stock defect)",
		      STR_EQ(queue(), "456") && a3q_unq == 0);
	check(on, "every resume reaches the B2 reconnect re-arm with its own unit",
	      nreconn == (on ? 4 : 1) && reconn_arg == (on ? &u[7] : &u[5]));
}

/* the whole sequence: case 2 re-queues the pre-empted unit, case 3 resumes that same unit,
 * its chain drains, and the next idle startany must not start it again */
static void
t_case2_case3_same_unit(int on)
{
	reset(on);
	a3091q_uqueue(&u[2]);			/* another unit waiting */
	a3091q_uqueue(&u[5]);			/* case 2: the unit whose selection was pre-empted */
	a3091q_resume(&u[5]);			/* case 3: and it is the one reselecting */
	u[5].comhead = 0;			/* its last command completes; it is not re-queued */
	a3091_istate = 0;			/* IDLE */
	a3091q_startany();			/* the completion's tail */
	a3091_istate = 0;
	a3091q_startany();
	if (on)
		check(on, "after case 2+3 on one unit, only the waiting unit is ever started",
		      nstarted == 1 && started[0] == &u[2] && nwild == 0 && STR_EQ(queue(), "-"));
	else
		check(on, "control: the drained unit is started from a null comhead (stock defect)",
		      nwild == 1);
}

/* (b) a stale drained entry at the head, however it got there */
static void
t_startany_drop(int on)
{
	reset(on);
	a3091q_uqueue(&u[1]);
	a3091q_uqueue(&u[3]);
	u[1].comhead = 0;			/* stale */
	a3091_istate = 0;
	a3091q_startany();
	if (on)
		check(on, "startany drops the drained head and starts the next unit",
		      a3q_drop == 1 && nstarted == 1 && started[0] == &u[3] && nwild == 0);
	else
		check(on, "control: startany starts the drained unit (stock defect)",
		      nwild == 1 && started[0] == &u[1]);
	reset(on);
	a3091q_uqueue(&u[1]);
	u[1].comhead = 0;
	a3091q_startany();			/* not IDLE */
	check(on, "startany does nothing while the chip is busy",
	      a3q_drop == 0 && nstarted == 0 && STR_EQ(queue(), "1"));
}

/* the walks are bounded: a corrupt queue costs a count, never a hang */
static void
t_walk_bounded(int on)
{
	if (!on)
		return;
	reset(on);
	a3091q_uqueue(&u[1]);
	a3091q_uqueue(&u[2]);
	u[2].next = &u[1];			/* a cycle 1 -> 2 -> 1 */
	a3091q_uqueue(&u[6]);			/* the stock append that follows rewrites 2's link */
	u[2].next = &u[1];			/* so close the cycle again for the second walk */
	a3091q_resume(&u[7]);
	check(on, "a cyclic queue: both walks stop and count it, the call still completes",
	      a3q_walkcap == 2 && nreconn == 1);
}

int
main(void)
{
	int on;

	printf("a3q_magic 0x%08x (want 0x41335121)\n", (unsigned)a3q_magic);
	if ((unsigned)a3q_magic != 0x41335121u)
		fails++;
	for (on = 1; on >= 0; on--) {
		t_double_link(on);
		t_resume_unlink(on);
		t_case2_case3_same_unit(on);
		t_startany_drop(on);
		t_walk_bounded(on);
	}
	printf("%s: %d failing\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
