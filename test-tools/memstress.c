/* memstress.c -- synthetic low-memory load (DRIVER-LINE-8).
 * Reproduces the I3 low-memory deadlock shape on a 32 MB AMIX: page cache flooded by read(2) of a big file,
 * dirty file pages from MAP_SHARED stores into a large file (pageout must push them through ufs_putpage ->
 * ufs_bmap -> bread of an indirect block -> buffer-cache growth), and dirty pages from write(2) of mixed sizes.
 * usage: memstress dir bigMB readers writers mappers anonMB secs [smallwriters]
 * smallwriters: the apkg-extract shape -- many files of 1..40 KB (fragment-sized tails, so the
 * buffer cache keeps freeing and reallocating buffers of different sizes), a rolling window of 400.
 * At the end it reports every child that ended before the SIGKILL, with its role and status, checks
 * that the rest ended by signal 9, and prints MEMSTRESS_DONE; it exits 1 if any child ended otherwise.
 * Second version (2026-10-21).  The proof version (8b7143a) had two faults in mapper(): its mmap of the
 * whole file exceeded the default 16 MB soft RLIMIT_VMEM, so every mapper exited 4 before its first
 * store, and its offset (rnd() * 4096L) % len overflowed 32 bits and went negative.                    */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXKIDS	64

static char buf[65536];
static long seed = 12345;

static long
rnd()
{
	seed = seed * 1103515245L + 12345L;
	return (seed >> 8) & 0x7fffff;
}

static void
mkbig(path, mb)
char *path;
long mb;
{
	struct stat st;
	int fd;
	long i;

	if (stat(path, &st) == 0 && st.st_size >= mb * 1048576L)
		return;
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { perror("big"); exit(2); }
	memset(buf, 'B', sizeof buf);
	for (i = 0; i < mb * 16; i++)
		if (write(fd, buf, 65536) != 65536) { perror("bigw"); exit(2); }
	close(fd);
}

static void
reader(path)
char *path;
{
	int fd;

	for (;;) {
		fd = open(path, O_RDONLY);
		if (fd < 0)
			_exit(3);
		while (read(fd, buf, 65536) > 0)
			;
		close(fd);
	}
}

static void
mapper(path, mb, id)
char *path;
long mb;
int id;
{
	int fd;
	char *p;
	long len, pages, off;
	struct rlimit rl;

	len = mb * 1048576L;
	pages = len / 4096L;
	seed += id * 7919;
	/* the soft RLIMIT_VMEM defaults to 16 MB (SVMMLIM); the mapping needs the whole file */
	if (getrlimit(RLIMIT_VMEM, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
		rl.rlim_cur = rl.rlim_max;
		if (setrlimit(RLIMIT_VMEM, &rl) < 0)
			perror("setrlimit");
	}
	fd = open(path, O_RDWR);
	if (fd < 0) { perror("mapper open"); _exit(4); }
	p = mmap((caddr_t) 0, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t) 0);
	if (p == (char *) -1) { perror("mmap"); _exit(4); }
	for (;;) {			/* dirty a random page of the big file */
		off = (rnd() % pages) * 4096L;
		p[off] = (char) id;
	}
}

static void
writer(dir, id)
char *dir;
int id;
{
	char name[256];
	int fd, k;
	long n, tot;

	k = 0;
	seed += id * 104729;
	for (;;) {
		sprintf(name, "%s/w%d.%d", dir, id, k % 3);
		fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd < 0)
			_exit(5);
		for (tot = 0; tot < 3 * 1048576L; tot += n) {
			n = 512 + rnd() % 20000;
			if (write(fd, buf, n) != n)
				break;
		}
		close(fd);
		k++;
	}
}

static void
small(dir, id)
char *dir;
int id;
{
	char name[256];
	int fd, k;
	long n;

	k = 0;
	seed += id * 31337;
	sprintf(name, "%s/s%d", dir, id);
	mkdir(name, 0755);
	for (;;) {
		sprintf(name, "%s/s%d/f%d", dir, id, k % 400);
		unlink(name);
		fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd < 0)
			_exit(7);
		n = 1024 + rnd() % 40000;
		if (write(fd, buf, n) != n) { close(fd); _exit(7); }
		close(fd);
		k++;
	}
}

static void
anon(mb)
long mb;
{
	char *p;
	long i;

	p = (char *) malloc(mb * 1048576L);
	if (!p)
		_exit(6);
	for (;;)
		for (i = 0; i < mb * 1048576L; i += 4096)
			p[i]++;
}

static pid_t kids[MAXKIDS];
static char *role[MAXKIDS];
static int done[MAXKIDS];
static int nkids;

/* fork one child of the given role; returns 0 in the child */
static int
spawn(what)
char *what;
{
	pid_t pid;

	pid = fork();
	if (pid < 0) {
		perror("fork");
		return -1;
	}
	if (pid > 0) {
		kids[nkids] = pid;
		role[nkids] = what;
		nkids++;
	}
	return pid;
}

static void
status(i, st)
int i, st;
{
	if (WIFEXITED(st))
		printf("memstress: %s pid %ld exited %d\n", role[i], (long) kids[i], WEXITSTATUS(st));
	else if (WIFSIGNALED(st))
		printf("memstress: %s pid %ld killed by signal %d\n", role[i], (long) kids[i], WTERMSIG(st));
	else
		printf("memstress: %s pid %ld status 0x%x\n", role[i], (long) kids[i], st);
}

int
main(argc, argv)
int argc;
char **argv;
{
	char big[256];
	long mb, amb, secs;
	int r, w, m, sw, i, st, early, bad;
	pid_t pid;

	sw = 0;
	if (argc != 8 && argc != 9) {
		fprintf(stderr, "usage: memstress dir bigMB readers writers mappers anonMB secs [small]\n");
		return 2;
	}
	if (argc == 9)
		sw = atoi(argv[8]);
	mb = atol(argv[2]); r = atoi(argv[3]); w = atoi(argv[4]); m = atoi(argv[5]);
	amb = atol(argv[6]); secs = atol(argv[7]);
	if (r < 0 || w < 0 || m < 0 || sw < 0 || r + w + m + sw + (amb > 0) > MAXKIDS) {
		fprintf(stderr, "memstress: at most %d children\n", MAXKIDS);
		return 2;
	}
	sprintf(big, "%s/big", argv[1]);
	mkbig(big, mb);
	printf("memstress: big %ld MB, %d readers %d writers %d mappers %d small anon %ld MB, %ld s\n",
	       mb, r, w, m, sw, amb, secs);
	fflush(stdout);
	for (i = 0; i < r; i++) if (spawn("reader") == 0) reader(big);
	for (i = 0; i < w; i++) if (spawn("writer") == 0) writer(argv[1], i);
	for (i = 0; i < m; i++) if (spawn("mapper") == 0) mapper(big, mb, i + 1);
	for (i = 0; i < sw; i++) if (spawn("small") == 0) small(argv[1], i);
	if (amb > 0 && spawn("anon") == 0) anon(amb);
	sleep((unsigned) secs);

	/* a child that ended by itself is a load that was not there: name it */
	early = 0;
	while ((pid = waitpid((pid_t) -1, &st, WNOHANG)) > 0)
		for (i = 0; i < nkids; i++)
			if (kids[i] == pid) { done[i] = 1; early++; printf("memstress: EARLY "); status(i, st); }
	for (i = 0; i < nkids; i++)
		if (!done[i])
			kill(kids[i], SIGKILL);
	bad = 0;
	for (i = 0; i < nkids; i++) {
		if (done[i])
			continue;
		if (waitpid(kids[i], &st, 0) != kids[i]) {
			bad++;
			printf("memstress: %s pid %ld NOT REAPED\n", role[i], (long) kids[i]);
		} else if (!WIFSIGNALED(st) || WTERMSIG(st) != SIGKILL) {
			bad++;
			printf("memstress: NOT KILLED ");
			status(i, st);
		}
	}
	printf("memstress: %d children, %d ended early, %d did not end by signal 9\n", nkids, early, bad);
	printf("MEMSTRESS_DONE\n");
	return early || bad ? 1 : 0;
}
