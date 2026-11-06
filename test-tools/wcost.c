/*
 * wcost.c -- what the write path costs: DIR [MB [BIGMB [N]]]  (the cost rows of ISSUE-120)
 *   1. a new file of MB megabytes written by 4 KiB pages, then fsync      (appends into fresh blocks)
 *   2. that file copied by 8 KiB reads and writes to a new file, fsync    (as cp does)
 *   3. a file of BIGMB megabytes written, then N random 4 KiB page rewrites in it, fsync (rewrites of uncached pages
 *      once BIGMB is past the page cache)
 * each timed with time() (1 s resolution), twice; prints RES lines.  The rows used 64 96 20000 at 64 MiB.
 * From amix kernel/k30's write-cost test.  Build: m68k-cbm-sysv4-gcc -O -o wcost wcost.c (or cc on the box).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/types.h>

static char buf[8192];

static long seq(char *name, long mb, int bs)
{
	int fd = open(name, O_RDWR | O_CREAT | O_TRUNC, 0600);
	long i, n = mb * 1024L * 1024L / bs;
	time_t t0 = time((time_t *)0);

	if (fd < 0)
		return -1;
	memset(buf, 0x44, sizeof buf);
	for (i = 0; i < n; i++)
		if (write(fd, buf, bs) != bs)
			return -1;
	fsync(fd);
	close(fd);
	return (long)(time((time_t *)0) - t0);
}

static long copy(char *from, char *to)
{
	int a = open(from, O_RDONLY), b = open(to, O_RDWR | O_CREAT | O_TRUNC, 0600), k;
	time_t t0 = time((time_t *)0);

	if (a < 0 || b < 0)
		return -1;
	while ((k = read(a, buf, sizeof buf)) > 0)
		if (write(b, buf, k) != k)
			return -1;
	fsync(b);
	close(a);
	close(b);
	return (long)(time((time_t *)0) - t0);
}

static long rewrite(char *name, long mb, long n)
{
	int fd = open(name, O_RDWR);
	long i, pages = mb * 1024L * 1024L / 4096;
	unsigned long s = 12345;
	time_t t0 = time((time_t *)0);

	if (fd < 0)
		return -1;
	memset(buf, 0x55, sizeof buf);
	for (i = 0; i < n; i++) {
		s = s * 1103515245UL + 12345UL;
		lseek(fd, (off_t)(((s >> 8) % pages) * 4096), SEEK_SET);
		if (write(fd, buf, 4096) != 4096)
			return -1;
	}
	fsync(fd);
	close(fd);
	return (long)(time((time_t *)0) - t0);
}

int main(int ac, char **av)
{
	char *dir = ac > 1 ? av[1] : "/tmp", a[256], b[256], c[256];
	long mb = ac > 2 ? atol(av[2]) : 16, big = ac > 3 ? atol(av[3]) : 96, n = ac > 4 ? atol(av[4]) : 4000;
	int k;

	sprintf(a, "%s/wc.a", dir);
	sprintf(b, "%s/wc.b", dir);
	sprintf(c, "%s/wc.c", dir);
	for (k = 0; k < 2; k++) {
		printf("RES wcost pass %d: write %ld MB by 4 KiB pages %ld s\n", k + 1, mb, seq(a, mb, 4096));
		printf("RES wcost pass %d: copy %ld MB by 8 KiB %ld s\n", k + 1, mb, copy(a, b));
		unlink(a);
		unlink(b);
		if (seq(c, big, 8192) < 0) {
			perror("big");
			return 2;
		}
		sync();
		printf("RES wcost pass %d: %ld random 4 KiB rewrites in %ld MB %ld s\n", k + 1, n, big, rewrite(c, big, n));
		unlink(c);
		fflush(stdout);
	}
	return 0;
}
