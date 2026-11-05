/*
 * swapguard.c -- swapadd fails with ENOMEM instead of sleeping forever on its anon array (ISSUE-111).
 *
 * THE BUG.  swapadd allocates a swap area's anon array, 16 bytes per page of the area, as one block:
 * kmem_zalloc(npages * 16, KM_SLEEP).  A block over 4 KiB comes from sptalloc, out of kvseg's fixed arena
 * (sptmap; 0x400 clicks of 4 KiB then, 0x800 since ISSUE-80).  When no free run of kvseg is large enough, kmem_alloc sleeps on
 * Km_OsizeWanted until some large kmem_free, which may never come: `swap -a`, or the rc script that adds the swap
 * slice's tail at boot, hangs.  Measured on this kernel (cut 68060-261031-55) in emulation, A4000 LC060/Z3660:
 * the largest free kvseg run at boot is 413 clicks at 64 MB and 636 at 16 MB; with one array click per MiB of swap
 * (patch_swapgeom.py's 4 KiB slots), 256 MiB is added at 64 MB and 512 MiB hangs, 512 MiB at 16 MB and 768 MiB
 * hangs, both asleep on Km_OsizeWanted.
 *
 * THE FIX, the 68030 line's (amix kernel/k30/src/swapguard030.c) at this kernel's page size.  After the final link
 * tools/swapguard-retarget.py retargets swapadd's callers (swapctl and swapfunc name swapadd; swa_latch, the
 * operand latch swapconf calls, names its global alias swapadd_real) to swapadd_guarded, swapadd's kmem_zalloc of
 * the anon array to swapguard_take, and the initializer of swg_swapadd from swapguard_swapadd to swapadd_real (a
 * call within this file would be a pc-relative branch, with no relocation to retarget; the pointer's initializer
 * always has one).  swapadd_guarded works out the array size from (lowblk, nblks) exactly as patch_swapgeom.py's
 * swapadd does (+0xfff, & ~0xfff, >> 12, * 16), allocates the array with KM_NOSLEEP -- ENOMEM when kvseg has no run
 * that large -- and leaves it for swapguard_take, which hands it over.  When swapadd clamped the area to its device
 * (the first area only) the size differs: swapguard_take frees the block and allocates the smaller one with
 * KM_NOSLEEP, both at spl7, so no interrupt can take the run between them.  It never sleeps: swapadd has no failure
 * exit past this point, and the area is already on swapinfo, so a failure there (nothing freed could serve the
 * smaller block: a pool block larger than what was freed, on a machine out of kernel map and pages) panics.
 * A block swapadd did not take (it failed before allocating) is freed on return.  Nothing else in swapadd changes.
 *
 * THE LIMIT.  The array stays allocated for as long as the area exists, so it is refused like a missing run when it
 * would pin over an eighth of the main store: with an 8 MiB arena nothing else would stop "swap -a" of a whole big
 * slice pinning several MiB on a 16 MiB machine, and the boot's stepping down (S90swap) relies on the refusal.
 * 16 MiB of RAM takes up to about 490 MiB of swap in one area, 128 MiB up to about 3.9 GiB.
 */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/errno.h>
#include <sys/kmem.h>
#include <sys/cmn_err.h>

#define	SWG_PAGESHIFT	12			/* swapadd's page: 4 KiB on this line (patch_swapgeom.py) */
#define	SWG_PAGE	(1 << SWG_PAGESHIFT)
#define	SWG_ANON	16			/* sizeof (struct anon): bytes of array per page */

extern int sleep(), maxmem;
extern void wakeup();

long swg_magic = 0x53574721;		/* "SWG!" */
long swg_calls = 0;			/* every swapadd */
long swg_nomem = 0;			/* refused with ENOMEM: no run of kvseg that large */
long swg_resized = 0;			/* arrays swapadd asked for at another size (the first area clamped) */
long swg_last = 0;			/* the last array size, bytes */

static caddr_t swg_block;		/* the array allocated for the swapadd in progress */
static u_int swg_size;
static int swg_busy;

/* swg_swapadd's initializer is retargeted to swapadd_real (swapadd); this placeholder never runs */
int
swapguard_swapadd()
{
	return EINVAL;
}
int (*swg_swapadd)() = swapguard_swapadd;

int
swapadd_guarded(vp, lowblk, nblks, name)
	caddr_t vp;
	u_int lowblk, nblks;
	char *name;
{
	u_int start, end, size;
	int error;

	swg_calls++;
	while (swg_busy)
		(void) sleep((caddr_t)&swg_busy, PZERO + 1);
	swg_busy = 1;
	/* swapadd's own rounding: the byte range [lowblk, lowblk + nblks) * 512 narrowed to whole pages */
	start = ((lowblk << 9) + SWG_PAGE - 1) & ~(SWG_PAGE - 1);
	end = ((lowblk + nblks) << 9) & ~(SWG_PAGE - 1);
	size = end > start ? ((end - start) >> SWG_PAGESHIFT) * SWG_ANON : 0;
	if (size != 0) {
		swg_block = (u_int)size > (u_int)maxmem << (SWG_PAGESHIFT - 3) ? 0 : (caddr_t)kmem_zalloc(size, KM_NOSLEEP);
		if (swg_block == 0) {
			swg_nomem++;
			swg_busy = 0;
			wakeup((caddr_t)&swg_busy);
			return ENOMEM;
		}
		swg_size = size;
		swg_last = size;
	}
	error = (*swg_swapadd)(vp, lowblk, nblks, name);
	if (swg_block != 0) {
		kmem_free(swg_block, swg_size);
		swg_block = 0;
	}
	swg_busy = 0;
	wakeup((caddr_t)&swg_busy);
	return error;
}

caddr_t
swapguard_take(size, flag)
	u_int size;
	int flag;
{
	caddr_t p;
	register int s;

	if (swg_block != 0 && size == swg_size) {
		p = swg_block;
		swg_block = 0;
		return p;
	}
	swg_resized++;
	__asm__ __volatile__ ("movew %%sr,%0; movew &0x2700,%%sr" : "=d" (s));
	if (swg_block != 0) {
		kmem_free(swg_block, swg_size);
		swg_block = 0;
	}
	p = (caddr_t)kmem_zalloc(size, KM_NOSLEEP);
	__asm__ __volatile__ ("movew %0,%%sr" : : "d" (s));
	if (p == 0)
		cmn_err(CE_PANIC, "swapadd: no kernel memory for a swap map of %d bytes", size);
	return p;
}
