/*
 * coreseg040.c -- a core dump passes over the pages its process may not read (ISSUE-116).
 *
 * Stock core_seg writes each run as_memory finds with one vn_rdwr from user space and stops at the first error, and
 * elfcore then gives up: a truncated file and no core flag in the wait status.  Before segvn_prot040.s a PROT_NONE page
 * did not fail: the copy restarted for ever and the machine hung.  Now its copy fails, and a guard page would end the
 * dump, so the run is divided by as_getprot and a page no read can reach is not written: a real hole, no blocks spent
 * on a large PROT_NONE reservation, and a run can hold good pages after a denied one.  When a run ends denied its last
 * byte is written from the kernel, so that the file reaches the length elfcore's program header gives.  Any error
 * on what is written still ends the dump, as stock: an I/O failure is not a denied page.
 *
 * Takes the symbol core_seg; the stock body stays at core_seg_stock (relink-040.sh).  Same arguments and calls as the
 * stock body at .text 0x3ef12.  p_as is at +124 of struct proc.  CORESEG=0 builds without this file.
 */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/errno.h>

#define	CS_PAGE		4096
#define	CS_P_AS		124
#define	CS_WRITE	1		/* enum uio_rw, as the stock body pushes it */
#define	CS_USER		0		/* enum uio_seg */
#define	CS_KERNEL	1
#define	CS_READ		1		/* PROT_READ, PROT_EXEC */
#define	CS_EXEC		4

extern int as_memory(), as_getprot(), vn_rdwr();

long core_holes = 0;			/* runs left as holes, since boot */

int
core_seg(p, vp, offset, addr, size, rlimit, cr)
	caddr_t p, vp, addr, cr;
	long offset, rlimit;
	u_int size;
{
	static char zero;		/* never written: a shared source of one zero byte */
	caddr_t as = *(caddr_t *)(p + CS_P_AS), base = addr, eaddr = addr + size, a, end, next;
	u_int len;
	int err, prot, denied;

	while (base < eaddr) {
		len = eaddr - base;
		if (as_memory(as, &base, &len) != 0)
			break;
		end = base + len;
		denied = 0;
		for (a = base; a < end; a = next) {
			/* from the page's start: as_getprot steps by 2 KiB from what it is given, and COFF data can start anywhere */
			prot = as_getprot(as, (caddr_t)((u_int)a & ~(CS_PAGE - 1)), &next);
			if (next > end)
				next = end;
			denied = (prot & (CS_READ | CS_EXEC)) == 0;
			if (denied) {
				core_holes++;
				continue;
			}
			err = vn_rdwr(CS_WRITE, vp, a, next - a, offset + (a - addr), CS_USER, 0, rlimit, cr, (int *)0);
			if (err)
				return err;
		}
		if (denied) {
			err = vn_rdwr(CS_WRITE, vp, &zero, 1, offset + (end - addr) - 1, CS_KERNEL, 0, rlimit, cr, (int *)0);
			if (err)
				return err;
		}
		base = end;
	}
	return 0;
}
