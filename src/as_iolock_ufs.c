/*
 * as_iolock_ufs.c -- ufs rwip's as_iolock, with pagecreate kept only for writes that start at the 8 KiB window and
 * cover it or run to the end of the file.
 *
 * THE BUG.  For a write of whole pages, as_iolock grants pagecreate: rwip then creates the pages it writes without
 * reading them (segmap_pagecreate) and asks ufs_bmap to allocate a new block alloc-only, without reading or zeroing
 * it.  The block's pages the write does not cover are then read from the disk block later, which still holds what
 * was there before -- another file's former data.  ufs_bmap only sees the write's end (on + n), so it cannot tell a
 * write of the block's last page from one of the whole block; on the direct blocks it does not look even at that.
 *
 * THE FIX.  As Solaris's ufs_wrip does: pagecreate (and so alloc-only) only when the write starts at the window
 * (uio_offset & MAXBOFFSET == 0) and covers it (n == MAXBSIZE) or runs to the end of the file (uio_offset + n >=
 * the size as_iolock was given).  Any other write faults its pages in, and a new block is allocated with alloc-only
 * off, so ufs_bmap zeroes it.  rwip's one call to as_iolock is retargeted to as_iolock_ufs after the link
 * (tools/ufs-holefix.sh, tools/iolockufs.py); the stock as_iolock is unchanged and nfs's rwvp still calls it.  The
 * pages as_iolock held for pagecreate are released by rwip's loop after the copy whether pagecreate is set or not.
 *
 * The same routine as amix kernel/k30's src/as_iolock_ufs.c, where it was written for the 030 line; only this
 * comment differs.
 */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/uio.h>

extern int as_iolock();

long ufs_pc_magic = 0x55504321;	/* "UPC!" */
long ufs_pc_calls = 0;		/* every call from rwip */
long ufs_pc_kept = 0;		/* pagecreate granted and kept */
long ufs_pc_cleared = 0;		/* pagecreate granted and taken back */

int
as_iolock_ufs(uio, iolpl, n, vp, isize, pagecreate)
	struct uio *uio;
	caddr_t iolpl;
	int n;
	caddr_t vp;
	int isize;
	int *pagecreate;
{
	int r = as_iolock(uio, iolpl, n, vp, isize, pagecreate);

	ufs_pc_calls++;
	if (*pagecreate) {
		if ((uio->uio_offset & (MAXBSIZE - 1)) == 0 && (r == MAXBSIZE || uio->uio_offset + r >= isize))
			ufs_pc_kept++;
		else {
			*pagecreate = 0;
			ufs_pc_cleared++;
		}
	}
	return r;
}
