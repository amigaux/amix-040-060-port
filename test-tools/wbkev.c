/* wbkev.c -- the kept-store table (a 68040's stores kept across a SIGSEGV handler) must not lose one process's store
 * for another's.  Run as root; exit status = stores lost.
 *
 *   wbkev fill   two unprivileged users fill what they can and keep it: uid 100 leaves a record at each of 8 stack depths
 *                by leaving its handler with longjmp, uid 101 the same with SIGSEGV ignored; both then wait.  Then 4 root
 *                processes each store into a PROT_NONE page, sleep in their handler (all 4 at once), repair the page and
 *                return: every root store must land.
 *   wbkev live   4 root processes sleep in their handlers with a store kept; meanwhile C reads a PROT_NONE page with no
 *                handler (nothing to keep) and D, also root, stores and repairs (its own store may be dropped: reported).
 *                The 4 stores must land.
 *
 * Build: m68k-cbm-sysv4-gcc -m68040 -O -o wbkev wbkev.c.  Meaningful on a 68040 only (the 68060 re-runs the store). */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/resource.h>
#define _POSIX_SOURCE 1	/* struct sigaction, with __STDC__ set */
#include <signal.h>
#include <setjmp.h>
#undef _POSIX_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#define PG 4096
#define NV 4
#define SLP 12
#define NPIN 8
static int zfd, pfd[2]; static char *pg; static int slp; static jmp_buf jb;
static char *anon(int prot) { char *p = mmap(0, PG, prot, MAP_PRIVATE, zfd, 0); if (p == (char *)-1) { perror("mmap"); _exit(90); } return p; }
static void h(int s) { if (slp) { write(pfd[1], "r", 1); sleep(slp); } mprotect(pg, PG, PROT_READ | PROT_WRITE); }
static int storer(int sleeps) { slp = sleeps; pg = anon(PROT_NONE); signal(SIGSEGV, h); *(volatile long *)pg = 0x11223344; return *(volatile long *)pg == 0x11223344 ? 0 : 3; }
static void out(int s) { longjmp(jb, 1); }
static int deep(int d) { volatile char pad[64]; pad[0] = d; if (d) return deep(d - 1) + pad[0]; *(volatile long *)pg = 1; return pad[0]; }
static void filler(int uid, int ign)	/* NPIN records, one per stack depth, none ever completed; then wait */
{
	volatile int i; struct sigaction sa;
	if (setuid(uid)) { perror("setuid"); _exit(98); }
	pg = anon(PROT_NONE);
	memset(&sa, 0, sizeof sa); sa.sa_handler = ign ? SIG_IGN : out;	/* sigaction: signal() would reset it at the first */
	sigaction(SIGSEGV, &sa, 0);
	for (i = 0; i < NPIN; i++) if (ign || !setjmp(jb)) deep(i);
	write(pfd[1], "f", 1);
	for (;;) pause();
}
static char *how(int st, char *b) { sprintf(b, "%s %d", WIFSIGNALED(st) ? "signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st)); return b; }
int main(int ac, char **av)
{
	pid_t v[NV], f1 = 0, f2 = 0, c, d; int i, st, lost = 0; char b, w[32]; struct rlimit rl;
	int fill = ac > 1 && !strcmp(av[1], "fill");
	if (ac < 2 || (!fill && strcmp(av[1], "live"))) { printf("usage: wbkev fill|live\n"); return 99; }
	if (getuid() != 0) { printf("run as root\n"); return 99; }
	zfd = open("/dev/zero", O_RDWR); pipe(pfd);
	rl.rlim_cur = rl.rlim_max = 0; setrlimit(RLIMIT_CORE, &rl);
	if (fill) {
		if ((f1 = fork()) == 0) filler(100, 0);
		if ((f2 = fork()) == 0) filler(101, 1);
		for (i = 0; i < 2; i++) if (read(pfd[0], &b, 1) != 1 || b != 'f') { printf("filler failed\n"); return 99; }
		printf("uid 100 (longjmp) and uid 101 (SIGSEGV ignored) each left %d records and wait\n", NPIN); fflush(stdout);
	}
	for (i = 0; i < NV; i++) if ((v[i] = fork()) == 0) { alarm(60); _exit(storer(SLP)); }
	for (i = 0; i < NV; i++) if (read(pfd[0], &b, 1) != 1 || b != 'r') { printf("pipe\n"); return 99; }
	printf("all %d root handlers running\n", NV); fflush(stdout);
	if (!fill) {
		if ((c = fork()) == 0) { char *q = anon(PROT_NONE); alarm(10); return *(volatile int *)q; }
		waitpid(c, &st, 0); printf("C (read, nothing to keep): %s\n", how(st, w));
		if ((d = fork()) == 0) { alarm(10); _exit(storer(0)); }
		waitpid(d, &st, 0); printf("D (root, a store to keep): %s%s\n", how(st, w), WIFEXITED(st) && WEXITSTATUS(st) == 3 ? " (its own store dropped)" : "");
	}
	for (i = 0; i < NV; i++) {
		waitpid(v[i], &st, 0);
		if (!WIFEXITED(st) || WEXITSTATUS(st)) { lost++; printf("root %d: %s: STORE LOST\n", i, how(st, w)); }
	}
	if (f1) { kill(f1, SIGKILL); waitpid(f1, &st, 0); }
	if (f2) { kill(f2, SIGKILL); waitpid(f2, &st, 0); }
	printf(lost ? "WBKEV %s FAIL %d\n" : "WBKEV %s PASS\n", av[1], lost);
	return lost;
}
