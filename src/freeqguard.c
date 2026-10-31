/*
 * freeqguard.c -- freeq with the queue pair taken off the STREAMS run and scan lists first (grimoire quirk 92).
 *
 * From amix kernel/k30/src/freeqguard030.c (f4aef26), the code unchanged: nothing in it is CPU-specific.
 *
 * THE BUG.  qattach pushes a module or opens a driver; when the open routine fails it undoes the attach with
 * qdetach(q, 0, 0, cr).  With clmode 0 the stock qdetach skips runqueues, the close, the run-list removal and the
 * flushes, and goes straight to the backq fixups and freeq.  An open that enabled its own queue before failing
 * (sockmod: the T_INFO_ACK is put on its read queue, QENAB, then the open returns an error) leaves the freed pair
 * on qhead; the next queuerun (from ureturn) calls q_qinfo->qi_srvp of freed memory: KERNEL FAULT vector 4 or
 * 0xB at a heap pc, backtrace ureturn -> queuerun.  Measured on the stock 2.1c link 80a1204f under prngd and
 * prngd-ctl traffic: one sockmod read queue (q_flag QENAB|QWANTR|QREADR|QUSE) at the head of the run list,
 * freed from qattach+0x184 -> qdetach+0x122.  strclose's own run-list walk covers only the write queue.
 *
 * THE FIX.  Every relocation naming freeq outside this file is retargeted to freeq_guarded after the final link
 * (tools/freeqguard-retarget.py; relink-040.sh, FREEQ_GUARD=0 builds without it).  At spl7
 * freeq_guarded unlinks q and WR(q) from the run list (qhead, qtail) and the scan list (scanqhead, scanqtail),
 * both chained through q_link, counts what it took off, then calls the stock freeq unchanged.  A pair on
 * neither list -- every close the stock code already cleaned up -- costs one walk of each list.
 */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/stream.h>

extern void freeq();
extern queue_t *qhead, *qtail, *scanqhead, *scanqtail;

long fqg_magic = 0x46514721;	/* "FQG!" */
long fqg_calls = 0;		/* every freeq */
long fqg_run = 0;		/* queues taken off the run list */
long fqg_scan = 0;		/* queues taken off the scan list */
long fqg_last = 0;		/* the last queue taken off either */

static long
fqg_unlink(hp, tp, rq)
	queue_t **hp, **tp, *rq;
{
	queue_t *q, *prev = 0, *next;
	long n = 0;

	for (q = *hp; q != 0; q = next) {
		next = q->q_link;
		if (q != rq && q != WR(rq)) {
			prev = q;
			continue;
		}
		if (prev)
			prev->q_link = next;
		else
			*hp = next;
		if (*tp == q)
			*tp = prev;
		q->q_link = 0;
		fqg_last = (long)q;
		n++;
	}
	return n;
}

void
freeq_guarded(q)
	queue_t *q;
{
	long s;

	fqg_calls++;
	__asm__ __volatile__ ("movew %%sr,%0; movew &0x2700,%%sr" : "=d" (s));
	fqg_run += fqg_unlink(&qhead, &qtail, q);
	fqg_scan += fqg_unlink(&scanqhead, &scanqtail, q);
	__asm__ __volatile__ ("movew %0,%%sr" : : "d" (s));
	freeq(q);
}
