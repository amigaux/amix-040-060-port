/*
 * ufs_bmap_hf.c -- ufs rwip's ufs_bmap, with alloc-only kept only for a block that is already allocated.
 *
 * THE BUG.  For a write of whole pages, as_iolock grants pagecreate: rwip then creates the pages it writes without
 * reading them (segmap_pagecreate) and asks ufs_bmap to allocate the block alloc-only, without reading or zeroing it.
 * When the block is new (a hole in the file, or past its end), the pages the write does not cover are later read from
 * the disk block, which still holds what was there before -- another file's former data.  ufs_bmap only sees the
 * write's end (on + n), so it cannot tell a write of the block's last page from one of the whole block; on the direct
 * blocks it does not look even at that.
 *
 * THE FIX.  Before rwip's call, look the block up (ufs_bmap with S_READ, which allocates nothing).  A hole, or an
 * error, turns alloc-only off: ufs_bmap then reads the new block before setting it in the inode, so every page of it
 * is zero-filled in the cache, and the write's own pages are found there by segmap_pagecreate and overwritten.  A
 * block already allocated keeps alloc-only, which then allocates nothing: the rewrite runs as stock, with no read.
 * The lookup runs under the inode lock rwip holds for the real call, so the block cannot change between the two.
 * rwip's one call to ufs_bmap is retargeted to ufs_bmap_hf after the link (tools/ufs-holefix.sh, tools/bmaphf.py);
 * as_iolock and every other caller of ufs_bmap are unchanged.
 *
 * The same routine as amix kernel/k30's src/ufs_bmap_hf.c, where it is used on the 030 line; only this comment
 * differs.
 */
#include <sys/types.h>
#include <sys/vnode.h>
#include <vm/seg.h>

extern int ufs_bmap();

#define UFS_HOLE ((daddr_t)-1)	/* sys/fs/ufs_inode.h */

long ufs_hf_magic = 0x55484621;	/* "UHF!" */
long ufs_hf_calls = 0;		/* every call from rwip */
long ufs_hf_holes = 0;		/* alloc-only asked for a new block, and taken back */
long ufs_hf_kept = 0;		/* alloc-only asked for an allocated block, and kept */

int
ufs_bmap_hf(ip, lbn, bnp, rabnp, size, rw, alloc_only)
	caddr_t ip;
	daddr_t lbn;
	daddr_t *bnp;
	daddr_t *rabnp;
	int size;
	enum seg_rw rw;
	int alloc_only;
{
	daddr_t bn = UFS_HOLE;	/* a lookup that stores nothing counts as a hole */

	ufs_hf_calls++;
	if (alloc_only && rw == S_WRITE) {
		if (ufs_bmap(ip, lbn, &bn, (daddr_t *)0, size, S_READ, 0) != 0 || bn == UFS_HOLE) {
			alloc_only = 0;
			ufs_hf_holes++;
		} else
			ufs_hf_kept++;
	}
	return ufs_bmap(ip, lbn, bnp, rabnp, size, rw, alloc_only);
}
