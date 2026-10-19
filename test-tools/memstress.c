/* memstress.c -- THROWAWAY guest load for the page-out reserve proof (2026-10-06, port station).
 * Reproduces the I3 low-memory deadlock shape on a 32 MB AMIX: page cache flooded by read(2) of a big file,
 * dirty file pages from MAP_SHARED stores into a large file (pageout must push them through ufs_putpage ->
 * ufs_bmap -> bread of an indirect block -> buffer-cache growth), and dirty pages from write(2) of mixed sizes.
 * usage: memstress dir bigMB readers writers mappers anonMB secs [smallwriters]
 * smallwriters: the apkg-extract shape -- many files of 1..40 KB (fragment-sized tails, so the
 * buffer cache keeps freeing and reallocating buffers of different sizes), a rolling window of 400.
 * Prints MEMSTRESS_DONE when the time is up and every child has been reaped.          */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char buf[65536];
static long seed = 12345;
static long rnd() { seed = seed * 1103515245L + 12345L; return (seed >> 8) & 0x7fffff; }

static void mkbig(char *path, long mb)
{
	struct stat st; int fd; long i;
	if (stat(path, &st) == 0 && st.st_size >= mb * 1048576L) return;
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { perror("big"); exit(2); }
	memset(buf, 'B', sizeof buf);
	for (i = 0; i < mb * 16; i++) if (write(fd, buf, 65536) != 65536) { perror("bigw"); exit(2); }
	close(fd);
}

static void reader(char *path)
{
	int fd; for (;;) { fd = open(path, O_RDONLY); if (fd < 0) _exit(3);
		while (read(fd, buf, sizeof buf) > 0) ; close(fd); }
}

static void mapper(char *path, long mb, int id)
{
	int fd; char *p; long len = mb * 1048576L, off;
	seed += id * 7919;
	fd = open(path, O_RDWR); if (fd < 0) _exit(4);
	p = mmap(0, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == (char *) -1) { perror("mmap"); _exit(4); }
	for (;;) { off = (rnd() * 4096L) % len; p[off] = (char) id; }	/* dirty a random page of the big file */
}

static void writer(char *dir, int id)
{
	char name[256]; int fd, k = 0; long n, tot;
	seed += id * 104729;
	for (;;) {
		sprintf(name, "%s/w%d.%d", dir, id, k % 3);
		fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) _exit(5);
		for (tot = 0; tot < 3 * 1048576L; tot += n) { n = 512 + rnd() % 20000; if (write(fd, buf, n) != n) break; }
		close(fd); k++;
	}
}

static void small(char *dir, int id)
{
	char name[256]; int fd, k = 0; long n;
	seed += id * 31337;
	sprintf(name, "%s/s%d", dir, id); mkdir(name, 0755);
	for (;;) {
		sprintf(name, "%s/s%d/f%d", dir, id, k % 400);
		unlink(name);
		fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) _exit(7);
		n = 1024 + rnd() % 40000;
		if (write(fd, buf, n) != n) { close(fd); _exit(7); }
		close(fd); k++;
	}
}

static void anon(long mb)
{
	char *p = malloc(mb * 1048576L); long i;
	if (!p) _exit(6);
	for (;;) for (i = 0; i < mb * 1048576L; i += 4096) p[i]++;
}

int main(int argc, char **argv)
{
	char big[256]; long mb, amb, secs; int r, w, m, i, n = 0; pid_t kids[64];
	int sw = 0;
	if (argc != 8 && argc != 9) { fprintf(stderr, "usage: memstress dir bigMB readers writers mappers anonMB secs [small]\n"); return 2; }
	if (argc == 9) sw = atoi(argv[8]);
	mb = atol(argv[2]); r = atoi(argv[3]); w = atoi(argv[4]); m = atoi(argv[5]); amb = atol(argv[6]); secs = atol(argv[7]);
	sprintf(big, "%s/big", argv[1]); mkbig(big, mb);
	printf("memstress: big %ld MB, %d readers %d writers %d mappers %d small anon %ld MB, %ld s\n", mb, r, w, m, sw, amb, secs);
	fflush(stdout);
	for (i = 0; i < r; i++) if ((kids[n++] = fork()) == 0) reader(big);
	for (i = 0; i < w; i++) if ((kids[n++] = fork()) == 0) writer(argv[1], i);
	for (i = 0; i < m; i++) if ((kids[n++] = fork()) == 0) mapper(big, mb, i + 1);
	for (i = 0; i < sw; i++) if ((kids[n++] = fork()) == 0) small(argv[1], i);
	if (amb > 0 && (kids[n++] = fork()) == 0) anon(amb);
	sleep(secs);
	for (i = 0; i < n; i++) kill(kids[i], SIGKILL);
	while (wait((int *) 0) > 0) ;
	printf("MEMSTRESS_DONE\n");
	return 0;
}
