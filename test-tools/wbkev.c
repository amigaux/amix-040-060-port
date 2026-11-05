/* wbkev.c -- a full kept-store table must not lose another process's store (68040).
 * Eight children each store into a PROT_NONE page; each handler says it is running, sleeps, then repairs the page
 * and returns, and the child checks its store landed.  While all eight sleep (the table full, every record's signal
 * sent): C reads a PROT_NONE page with no handler (nothing to keep), then D stores into one (a store to keep) and
 * repairs it.  Exit status = children whose store was lost.  D's own store may be dropped (the table is full): reported.
 * Build: m68k-cbm-sysv4-gcc -m68040 -O -o wbkev wbkev.c.  Meaningful on a 68040 only (the 68060 re-runs the store). */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <signal.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#define PG 4096
#define NCH 8
#define SLP 12
static int zfd, pfd[2]; static char *pg; static int slp;
static char *anon(int prot) { char *p = mmap(0, PG, prot, MAP_PRIVATE, zfd, 0); if (p == (char *)-1) { perror("mmap"); _exit(90); } return p; }
static void h(int s) { if (slp) { write(pfd[1], "r", 1); sleep(slp); } mprotect(pg, PG, PROT_READ | PROT_WRITE); }
static int storer(int sleeps) { slp = sleeps; pg = anon(PROT_NONE); signal(SIGSEGV, h); *(volatile long *)pg = 0x11223344; return *(volatile long *)pg == 0x11223344 ? 0 : 3; }
int main(void)
{
	pid_t ch[NCH], c, d; int i, st, lost = 0; char b; struct rlimit rl;
	zfd = open("/dev/zero", O_RDWR); pipe(pfd);
	rl.rlim_cur = rl.rlim_max = 0; setrlimit(RLIMIT_CORE, &rl);
	for (i = 0; i < NCH; i++) if ((ch[i] = fork()) == 0) { alarm(60); _exit(storer(SLP)); }
	for (i = 0; i < NCH; i++) if (read(pfd[0], &b, 1) != 1) { printf("pipe\n"); return 99; }
	printf("all %d handlers running\n", NCH); fflush(stdout);
	if ((c = fork()) == 0) { char *q = anon(PROT_NONE); alarm(10); return *(volatile int *)q; }
	waitpid(c, &st, 0); printf("C (read, nothing to keep): %s %d\n", WIFSIGNALED(st) ? "signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
	if ((d = fork()) == 0) { alarm(10); _exit(storer(0)); }
	waitpid(d, &st, 0); printf("D (store to keep): %s %d%s\n", WIFSIGNALED(st) ? "signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st),
		WIFEXITED(st) && WEXITSTATUS(st) == 3 ? " (its own store dropped, the table full)" : "");
	for (i = 0; i < NCH; i++) {
		waitpid(ch[i], &st, 0);
		if (!WIFEXITED(st) || WEXITSTATUS(st)) { lost++; printf("child %d: %s %d: STORE LOST\n", i, WIFSIGNALED(st) ? "signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st)); }
	}
	printf(lost ? "WBKEV FAIL %d\n" : "WBKEV PASS\n", lost);
	return lost;
}
