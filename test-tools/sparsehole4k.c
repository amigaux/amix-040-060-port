/*
 * sparsehole4k.c -- a whole-page write into a hole in the middle of a file, and what the rest of the new block reads
 * (ISSUE-120).  amix kernel/k30's tests/sparsehole/sparsehole.c (2 KiB pages) with 4 KiB pages, the written page
 * chosen, and a past-end-of-file mode.
 *
 * ufs allocates a whole block for a write into a hole.  A page-aligned write of whole pages (the pagecreate case) made
 * stock ufs_bmap allocate the block without reading or zeroing it, and only the pages written were created in the
 * cache; the block's other pages were later read from the disk block, which still held whatever was there before.
 * For a block among a file's first 12 (the direct blocks) that is any such write; for a block mapped through an
 * indirect block, ufs_bmap reads the new block in unless the write reaches its last page.  The test:
 *
 *   1. writes a filler file of MB megabytes of 0x5a and removes it, so free blocks hold 0x5a;
 *   2. makes NF files of 41 blocks of 8 KiB: 0x11 in blocks 0, 12 and 40, the rest holes, so every hole is in the
 *      middle of its file; blocks 1-11 are direct, 13-39 indirect;
 *   3. writes one 4 KiB page of 0x22, page WP of the 8 KiB block, into blocks 1, 3, 5, 7, 9 and 11 (direct) and 15,
 *      17, 19, 21, 23 and 25 (indirect) of each file;
 *   4. writes and reads back MB megabytes of another file and removes it, to push the files' pages out of the cache;
 *   5. reads each written block back: zeros, except the page of 0x22.
 *
 * A page that should be zero and is not is counted, as direct or indirect, with how many hold the filler's 0x5a.  A
 * count of 0 with no 0x5a anywhere can also mean the new blocks never landed on the filler's, so the 0x5a count is
 * printed beside it.  Exit 1 when a page is wrong.  It assumes 8 KiB blocks (the 1.1 file systems).
 *
 * sparsehole4k DIR [NF [MB [WP]]]
 *   WP 1 (the default) writes the block's second page, which also skips the indirect path's read; WP 0 the first page
 *   (the indirect blocks are then the control).  WP eof writes page 1 of a new block past the end of the file instead
 *   (block 0 of an empty file, block 15 after block 14): rwip zeroes that gap itself, so stock is clean there too.
 *
 * Build: m68k-cbm-sysv4-gcc -O -o sparsehole4k sparsehole4k.c (or cc on the box).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>

#define BLK 8192L
#define PG 4096

static char buf[8192];
static int wp = 1;
static int blocks[] = { 1, 3, 5, 7, 9, 11, 15, 17, 19, 21, 23, 25 };	/* the first six direct, the rest indirect */

static int wr(int fd, long off, int c, long n)
{
	memset(buf, c, sizeof buf);
	if (lseek(fd, off, SEEK_SET) < 0)
		return -1;
	while (n > 0) {
		long k = n > (long)sizeof buf ? (long)sizeof buf : n;
		if (write(fd, buf, k) != k)
			return -1;
		n -= k;
	}
	return 0;
}

static int churn(char *name, int c, long mb, int readback)
{
	int fd = open(name, O_RDWR | O_CREAT | O_TRUNC, 0600);
	long i;

	if (fd < 0 || wr(fd, 0L, c, mb * 1024L * 1024L) < 0)
		return -1;
	fsync(fd);
	if (readback) {
		lseek(fd, 0L, SEEK_SET);
		for (i = 0; i < mb * 128L; i++)
			if (read(fd, buf, sizeof buf) != (int)sizeof buf)
				break;
	}
	close(fd);
	return unlink(name);
}

int main(int ac, char **av)
{
	char *dir = ac > 1 ? av[1] : "/tmp", f[256], g[256], h[256];
	long nf = ac > 2 ? atol(av[2]) : 16, mb = ac > 3 ? atol(av[3]) : 24, bad[2], stale[2], n[2], page, off;
	int fd, i, j, k, want, ind, shown = 0, nb, blk;
	int eof = ac > 4 && strcmp(av[4], "eof") == 0;
	static int eofblocks[] = { 0, 15 };

	if (ac > 4)
		wp = eof ? 1 : atoi(av[4]);
	sprintf(g, "%s/sh.fill", dir);
	sprintf(h, "%s/sh.evict", dir);
	bad[0] = bad[1] = stale[0] = stale[1] = n[0] = n[1] = 0;
	if (churn(g, 0x5a, mb, 0) < 0) {
		perror("filler");
		return 2;
	}
	for (i = 0; i < nf; i++) {
		sprintf(f, "%s/sh.%d", dir, i);
		if (eof) {	/* one page written one page past EOF into a new block: block 0 of an empty file, block 15 after block 14 */
			if ((fd = open(f, O_RDWR | O_CREAT | O_TRUNC, 0600)) < 0 || wr(fd, (long)PG, 0x22, (long)PG) < 0
			    || wr(fd, 14 * BLK, 0x11, BLK) < 0 || wr(fd, 15 * BLK + PG, 0x22, (long)PG) < 0
			    || wr(fd, 40 * BLK, 0x11, BLK) < 0) {
				perror(f);
				return 2;
			}
			fsync(fd);
			close(fd);
			continue;
		}
		if ((fd = open(f, O_RDWR | O_CREAT | O_TRUNC, 0600)) < 0 || wr(fd, 0L, 0x11, BLK) < 0
		    || wr(fd, 12 * BLK, 0x11, BLK) < 0 || wr(fd, 40 * BLK, 0x11, BLK) < 0) {
			perror(f);
			return 2;
		}
		for (k = 0; k < (int)(sizeof blocks / sizeof blocks[0]); k++)
			if (wr(fd, blocks[k] * BLK + wp * PG, 0x22, (long)PG) < 0) {
				perror("hole write");
				return 2;
			}
		fsync(fd);
		close(fd);
	}
	sync();
	if (churn(h, 0x33, mb, 1) < 0) {
		perror("evict");
		return 2;
	}
	sync();
	for (i = 0; i < nf; i++) {
		sprintf(f, "%s/sh.%d", dir, i);
		if ((fd = open(f, O_RDONLY)) < 0) {
			perror(f);
			return 2;
		}
		nb = eof ? 2 : (int)(sizeof blocks / sizeof blocks[0]);
		for (k = 0; k < nb; k++) {
			blk = eof ? eofblocks[k] : blocks[k];
			ind = blk > 11;
			off = blk * BLK;
			lseek(fd, off, SEEK_SET);
			if (read(fd, buf, (int)BLK) != (int)BLK) {
				perror("read");
				return 2;
			}
			for (page = 0; page < (int)(BLK / PG); page++) {
				want = page == wp ? 0x22 : 0;
				if (page != wp)
					n[ind]++;
				for (j = 0; j < PG; j++)
					if ((buf[page * PG + j] & 0xff) != want)
						break;
				if (j == PG)
					continue;
				bad[ind]++;
				if ((buf[page * PG + j] & 0xff) == 0x5a)
					stale[ind]++;
				if (shown++ < 20)
					printf("RES sparsehole BAD %s file %d block %d page %ld (offset %ld): byte %d is 0x%02x, want 0x%02x\n",
					    ind ? "indirect" : "direct", i, blk, page, off + page * PG, j,
					    buf[page * PG + j] & 0xff, want);
			}
		}
		close(fd);
		unlink(f);
	}
	printf("RES sparsehole: direct %ld of %ld pages wrong (%ld the filler's 0x5a); indirect control %ld of %ld wrong "
	    "(%ld 0x5a); %ld files, %s page %d\n", bad[0], n[0], stale[0], bad[1], n[1], stale[1], nf,
	    eof ? "past-EOF write at" : "written", wp);
	return bad[0] || bad[1] ? 1 : 0;
}
