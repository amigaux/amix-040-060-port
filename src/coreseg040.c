/*
 * coreseg040.c -- a core dump passes over the pages its process may not read (ISSUE-116).
 *
 * Stock core_seg writes each run as_memory finds with one vn_rdwr from user space and stops at the first error, and
 * elfcore then gives up: a truncated file and no core flag in the wait status.  Before segvn_prot040.s a PROT_NONE page
 * did not fail: the copy restarted for ever and the machine hung.  Now it fails with EFAULT, and a guard page would end
 * the dump, so on EFAULT the run is written again a page at a time and a page that faults stays a hole in the file.  A
 * run can hold good pages after a denied one (adjacent mappings are one run to as_memory), so skipping the rest of the
 * run would lose them.  When a run's last page is denied its last byte is written from the kernel, so that the file
 * reaches the length elfcore's program header gives.
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

extern int as_memory(), vn_rdwr();

long core_holes = 0;			/* pages left as holes, since boot */

static int
core_pages(vp, base, len, off, rlimit, cr)
	caddr_t vp, base, cr;
	u_int len;
	long off, rlimit;
{
	static char zero;
	caddr_t a = base, end = base + len, next;
	int err, denied = 0;

	while (a < end) {
		next = (caddr_t)(((u_int)a + CS_PAGE) & ~(CS_PAGE - 1));
		if (next > end)
			next = end;
		err = vn_rdwr(CS_WRITE, vp, a, next - a, off + (a - base), CS_USER, 0, rlimit, cr, (int *)0);
		denied = err == EFAULT;
		if (denied)
			core_holes++;
		else if (err)
			return err;
		a = next;
	}
	return denied ? vn_rdwr(CS_WRITE, vp, &zero, 1, off + len - 1, CS_KERNEL, 0, rlimit, cr, (int *)0) : 0;
}

int
core_seg(p, vp, offset, addr, size, rlimit, cr)
	caddr_t p, vp, addr, cr;
	long offset, rlimit;
	u_int size;
{
	caddr_t as = *(caddr_t *)(p + CS_P_AS), base = addr, eaddr = addr + size;
	u_int len;
	int err;

	while (base < eaddr) {
		len = eaddr - base;
		if (as_memory(as, &base, &len) != 0)
			break;
		err = vn_rdwr(CS_WRITE, vp, base, len, offset + (base - addr), CS_USER, 0, rlimit, cr, (int *)0);
		if (err == EFAULT)
			err = core_pages(vp, base, len, offset + (base - addr), rlimit, cr);
		if (err)
			return err;
		base += len;
	}
	return 0;
}
