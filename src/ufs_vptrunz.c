/*
 * ufs_vptrunz.c -- ufs_itrunc's pvn_vptrunc call, with the zeroed tail of the last block written to disk
 * first (grimoire quirk 91).
 *
 * THE BUG.  Past the 12 direct blocks ufs keeps a file's last block whole.  On a shrink to a length M that
 * is not block-aligned, ufs_itrunc calls pvn_vptrunc(vp, M, fs_bsize - blkoff(M)) to zero [M, end of M's
 * block), and the zeros do not reach the disk:
 *   - warm (some page of the file cached): pvn_vptrunc zeroes the range through segkmap and releases it
 *     with SM_WRITE|SM_ASYNC, then aborts every page at or past M.  With the 8 KiB pages this code was
 *     written for, M's own page covers the rest of the block and survives; with Amix's 2 KiB pages
 *     (the 030 line) and this port's 4 KiB pages [roundup(M, PAGESIZE), end of the block) is measured
 *     to keep the old bytes on disk, through a reboot (k46, 2026-10-30);
 *   - cold (no page of the file cached): pvn_vptrunc returns at once (v_pages == NULL) and zeroes nothing,
 *     so all of [M, end of the block) keeps the old bytes.
 * When the file grows back over that range, the old contents are read again.  Measured on stock 2.1c and
 * on both kernel lines, with an 8 KiB-block ufs.
 *
 * THE FIX.  ufs_itrunc's reference to pvn_vptrunc is renamed to ufs_vptrunz in the ufs object (one
 * symbol-table string; tools/ufs-tailzero.sh, UFS_TAILZERO=0 builds without it).  When the shrink cuts
 * into a kept block past the direct blocks, ufs_vptrunz first zeroes [M, end of the block) itself, through
 * segkmap in MAXBSIZE windows, and releases each window with SM_WRITE alone: a synchronous VOP_PUTPAGE, so
 * ufs_putpage writes the zeroed pages to the block (i_size is still the old length here: ufs_itrunc sets it
 * after this call) before anything can abort them.  kzero faults the pages in, so the cold case is covered
 * too; past the old EOF (the quirk-90 shape) kzero stops at the first page it cannot bring in and returns
 * -1, and nothing beyond the old EOF was ever this file's.  Then it calls the stock pvn_vptrunc, unchanged,
 * which zeroes again in the cache and aborts the pages past M.  Every other call -- block-aligned M, M
 * inside the direct blocks -- is exactly the stock pvn_vptrunc.  It uses only what the ufs object imports
 * already: segkmap, segmap_getmap, segmap_release, kzero, pvn_vptrunc.
 *
 * The same routine as amix kernel/k30's src/ufs_vptrunz.c (1be27f8), where it was found and first built;
 * only this comment differs.
 */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/sysmacros.h>
#include <sys/systm.h>
#include <sys/vnode.h>
#include <sys/fs/ufs_fs.h>
#include <sys/fs/ufs_inode.h>
#include <vm/seg.h>
#include <vm/seg_map.h>

extern void pvn_vptrunc();
extern int kzero();
extern struct seg *segkmap;

long qz_magic = 0x515a5421;	/* "QZT!" */
long qz_calls = 0;		/* every call from ufs_itrunc */
long qz_tail = 0;		/* shrinks whose block tail was zeroed and written first */
long qz_cold = 0;		/* ... of them, with no page of the file cached on entry */
long qz_kzfail = 0;		/* windows where kzero stopped early (a page it could not bring in) */
long qz_puterr = 0;		/* windows whose synchronous release returned an error */

void
ufs_vptrunz(vp, vplen, zbytes)
	struct vnode *vp;
	u_int vplen, zbytes;
{
	struct fs *fs;
	addr_t addr;
	u_int off, base, end, n;

	qz_calls++;
	fs = VTOI(vp)->i_fs;
	if (zbytes != 0 && lblkno(fs, vplen) >= NDADDR) {
		qz_tail++;
		if (vp->v_pages == NULL)
			qz_cold++;
		end = (u_int)lblkno(fs, vplen) * fs->fs_bsize + fs->fs_bsize;
		for (off = vplen; off < end; off += n) {
			base = off & MAXBMASK;
			n = MIN(end, base + MAXBSIZE) - off;
			addr = segmap_getmap(segkmap, vp, base);
			if (kzero(addr + (off - base), n) != 0)
				qz_kzfail++;
			if (segmap_release(segkmap, addr, SM_WRITE) != 0)
				qz_puterr++;
		}
	}
	pvn_vptrunc(vp, vplen, zbytes);
}
