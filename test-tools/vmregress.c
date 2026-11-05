/*
 * vmregress.c -- what the fault path must still do, one line per case, each in its own child under a time limit.
 *
 * Run it after any change to segvn_faultpage, hardbus or the user-fault wrappers: copy-on-write after fork, private and
 * shared file mappings, stack growth, exec of shared text, mprotect up and down on part of a mapping, /proc writes to
 * text (a breakpoint), kernel copies into every kind of page, a core dump, the time a fault takes, then pages the program
 * may not use: PROT_NONE and execute-only, through /proc, kernel copies and a core dump.
 *
 *   vmregress [DIR]       DIR (default /tmp) holds the work files; run it as root, or as anyone for all but the /proc case
 *
 * Prints PASS/FAIL per case and "VMREGRESS PASS" or "VMREGRESS FAIL n"; exit status = failures.  A case that hangs dies by
 * alarm and counts as a failure, so a spin shows as FAIL, not as a stuck run (a hang in the kernel's own copy cannot be
 * killed: the last line printed then names the case).
 * Build: m68k-cbm-sysv4-gcc -m68040 -O -o vmregress vmregress.c   (or the guest's /usr/ccs/bin/cc)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#define _POSIX_SOURCE 1	/* struct sigaction, with __STDC__ set */
#include <signal.h>
#undef _POSIX_SOURCE
#include <siginfo.h>
#ifndef SA_SIGINFO
#define SA_SIGINFO 8
#endif
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/times.h>

#define PG 4096
static char work[256], *dir = "/tmp";
static int fails, zfd;

static char *file(char *leaf, int pages, int fill)
{
	static char b[PG];
	int fd, i;
	sprintf(work, "%s/vmr.%s", dir, leaf);
	fd = open(work, O_RDWR | O_CREAT | O_TRUNC, 0666);
	memset(b, fill, PG);
	for (i = 0; i < pages; i++)
		write(fd, b, PG);
	close(fd);
	return work;
}

static char *anon(int len, int prot)
{
	char *p = mmap((caddr_t)0, len, prot, MAP_PRIVATE, zfd, 0);
	if (p == (char *)-1) { printf("mmap: %s\n", strerror(errno)); exit(90); }
	return p;
}

/* each case: exit 0 for right; 1.. names the wrong step */
static int cow(void)
{
	char *p = anon(8 * PG, PROT_READ | PROT_WRITE); int i, st; pid_t c;
	for (i = 0; i < 8; i++) p[i * PG] = 'p';
	if ((c = fork()) == 0) {
		for (i = 0; i < 8; i++) { if (p[i * PG] != 'p') _exit(1); p[i * PG] = 'c'; }
		for (i = 0; i < 8; i++) if (p[i * PG] != 'c') _exit(2);
		_exit(0);
	}
	for (i = 0; i < 8; i += 2) p[i * PG] = 'P';
	waitpid(c, &st, 0);
	if (st) return 3;
	for (i = 0; i < 8; i++) if (p[i * PG] != (i % 2 ? 'p' : 'P')) return 4;
	return 0;
}

static int privfile(void)
{
	int fd = open(file("priv", 4, 'f'), O_RDWR), rb; char *p, b[1];
	p = mmap((caddr_t)0, 4 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	if (p == (char *)-1) return 1;
	if (p[PG] != 'f') return 2;
	p[PG] = 'X';				/* the page goes private */
	if (p[PG] != 'X' || p[2 * PG] != 'f') return 3;
	lseek(fd, (long)PG, 0); rb = read(fd, b, 1);
	if (rb != 1 || b[0] != 'f') return 4;	/* the file does not see it */
	munmap(p, 4 * PG); close(fd);
	return 0;
}

static int sharedfile(void)
{
	int fd = open(file("shar", 4, 's'), O_RDWR); char *p, *q, b[1]; pid_t c; int st;
	p = mmap((caddr_t)0, 4 * PG, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	q = mmap((caddr_t)0, 4 * PG, PROT_READ, MAP_SHARED, fd, 0);
	if (p == (char *)-1 || q == (char *)-1) return 1;
	p[PG + 5] = 'Y';
	if (q[PG + 5] != 'Y') return 2;
	if ((c = fork()) == 0) { p[2 * PG] = 'Z'; _exit(0); }
	waitpid(c, &st, 0);
	if (q[2 * PG] != 'Z') return 3;
	msync((caddr_t)p, 4 * PG, MS_SYNC);
	lseek(fd, (long)PG + 5, 0); read(fd, b, 1);
	if (b[0] != 'Y') return 4;
	close(fd);
	return 0;
}

static int deep(int n) { volatile char b[8192]; b[0] = n; b[8191] = n; return n ? deep(n - 1) + b[0] - b[8191] : 0; }
static int stack(void) { return deep(800) ? 1 : 0; }	/* about 6.5 MiB of stack, grown by faults */

static int execs(void)
{
	int i, st; pid_t c;
	for (i = 0; i < 40; i++) {
		if ((c = fork()) == 0) { execl("/bin/true", "true", (char *)0); _exit(9); }
		waitpid(c, &st, 0);
		if (st) return 1;
	}
	if ((c = fork()) == 0) { execl("/bin/sh", "sh", "-c", "ls / | wc -l > /dev/null", (char *)0); _exit(9); }
	waitpid(c, &st, 0);
	return st ? 2 : 0;
}

static int caught;
static void seg(int s) { caught = s; _exit(50 + (s == SIGSEGV ? 0 : 1)); }
static int probe(char *a, int wr, int want)	/* want: 0 access works, 1 it is SIGSEGV */
{
	int st; pid_t c;
	if ((c = fork()) == 0) {
		signal(SIGSEGV, seg); signal(SIGBUS, seg); alarm(8);
		if (wr) *(volatile char *)a = 1; else if (*(volatile char *)a == 77) _exit(0);
		_exit(0);
	}
	waitpid(c, &st, 0);
	if (want) return !(WIFEXITED(st) && WEXITSTATUS(st) == 50);
	return !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
}

static int mprot(void)
{
	char *p = anon(6 * PG, PROT_READ | PROT_WRITE); int i;
	for (i = 0; i < 6; i++) p[i * PG] = 1;
	if (mprotect((caddr_t)p + PG, 2 * PG, PROT_READ)) return 1;
	if (probe(p + PG, 1, 1)) return 2;		/* part of a mapping read-only: a write is refused */
	if (probe(p + PG, 0, 0)) return 3;		/* a read is not */
	if (probe(p, 1, 0) || probe(p + 3 * PG, 1, 0)) return 4;
	if (mprotect((caddr_t)p + PG, 2 * PG, PROT_NONE)) return 5;
	if (probe(p + 2 * PG, 0, 1)) return 6;		/* none: a read is refused */
	if (mprotect((caddr_t)p + PG, 2 * PG, PROT_READ | PROT_WRITE)) return 7;
	if (probe(p + PG, 1, 0)) return 8;		/* and back up */
	if (p[PG] != 1) return 9;
	p = anon(4 * PG, PROT_NONE);			/* a whole segment: none, up, none */
	if (probe(p, 0, 1) || probe(p, 1, 1)) return 10;
	if (mprotect((caddr_t)p, 4 * PG, PROT_READ | PROT_WRITE)) return 11;
	p[0] = 5; if (p[0] != 5) return 12;
	if (mprotect((caddr_t)p, 4 * PG, PROT_READ)) return 13;
	if (probe(p, 1, 1) || probe(p, 0, 0)) return 14;
	return 0;
}

static void target(void) { }			/* the text a breakpoint goes into */

/* the kernel's own copies, into and out of each kind of page */
static int copies(void)
{
	static char buf[PG]; char *a, *ro, *no, *fp, *sp; int fd, sfd, n;
	char sb[64];
	fd = open(file("copy", 4, 'k'), O_RDWR);
	a = anon(PG, PROT_READ | PROT_WRITE);			/* copyout into a fresh anon page */
	if (read(fd, a, 64) != 64 || a[63] != 'k') return 1;
	lseek(fd, 0L, 0); if (read(fd, sb, 64) != 64 || sb[63] != 'k') return 2;	/* the stack */
	fp = mmap((caddr_t)0, 2 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	sfd = open(file("copy2", 2, 'q'), O_RDWR);
	sp = mmap((caddr_t)0, 2 * PG, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0);
	if (fp == (char *)-1 || sp == (char *)-1) return 3;
	lseek(fd, 0L, 0); if (read(fd, fp + PG, 16) != 16 || fp[PG] != 'k') return 4;	/* private file page, COW by copyout */
	lseek(fd, 0L, 0); if (read(fd, sp + 8, 16) != 16 || sp[8] != 'k') return 5;	/* shared file page */
	if (write(fd, sp, 16) != 16 || write(fd, fp, 16) != 16) return 6;		/* copyin from both */
	if (write(fd, (char *)target, 16) != 16) return 7;				/* copyin from text */
	ro = anon(PG, PROT_READ);
	errno = 0; lseek(fd, 0L, 0); n = read(fd, ro, 16);
	if (n != -1 || errno != EFAULT) return 8;		/* copyout into read-only: EFAULT */
	if (write(fd, ro, 16) != 16) return 9;			/* copyin from it works */
	no = anon(2 * PG, PROT_NONE);
	errno = 0; n = write(fd, no, 16);
	if (n != -1 || errno != EFAULT) return 10;		/* copyin from no access: EFAULT, not a hang */
	errno = 0; n = read(fd, no, 16);
	if (n != -1 || errno != EFAULT) return 11;		/* copyout into no access */
	errno = 0; n = write(fd, (char *)0x7ffe0000, 16);
	if (n != -1 || errno != EFAULT) return 12;		/* nothing mapped */
	return 0;
}

static int bpt(void)	/* /proc: read and write text, as a debugger's breakpoint does; the child runs it */
{
	int fd, p[2], st; pid_t c; char nm[32], go; unsigned short w, orig;
	pipe(p);
	if ((c = fork()) == 0) {
		close(p[1]); read(p[0], &go, 1);
		target();
		_exit(5);			/* the patched word never lets it get here */
	}
	sprintf(nm, "/proc/%05d", (int)c);
	fd = open(nm, O_RDWR);
	if (fd < 0) { close(p[1]); kill(c, 9); waitpid(c, &st, 0); return errno == EACCES ? 0 : 1; }
	lseek(fd, (long)target, 0);
	if (read(fd, (char *)&orig, 2) != 2) return 2;
	w = 0x4e4f;			/* trap #15: a breakpoint's shape */
	lseek(fd, (long)target, 0);
	if (write(fd, (char *)&w, 2) != 2) return 3;
	lseek(fd, (long)target, 0);
	if (read(fd, (char *)&w, 2) != 2 || w != 0x4e4f) return 4;
	if (*(unsigned short *)target != orig) return 5;	/* the parent's copy of the text must not change */
	close(fd);
	write(p[1], "g", 1); close(p[1]);
	waitpid(c, &st, 0);
	if (!WIFSIGNALED(st)) return 6;		/* it died of the breakpoint */
	return 0;
}

static int core(void)
{
	int st; pid_t c; struct stat sb; char nm[300];
	sprintf(nm, "%s/core", dir); unlink(nm);
	if ((c = fork()) == 0) { chdir(dir); *(volatile int *)0x7ffe0000 = 1; _exit(0); }
	waitpid(c, &st, 0);
	if (!WIFSIGNALED(st)) return 1;
	if (stat(nm, &sb) != 0) return WCOREDUMP(st) ? 2 : 3;
	unlink(nm);
	return sb.st_size > 0 ? 0 : 4;
}

/*
 * Pages the program may not use.  The kernel must refuse them and go on working: each of these hung or panicked the
 * machine when the fault path restarted a denied access for ever.  Last in the run, since an old kernel stops here.
 */
static void rts_at(char *p) { ((void (*)(void))p)(); }

static int sig_of(void (*f)(char *), char *p)
{
	int st; pid_t c;
	if ((c = fork()) == 0) { alarm(10); f(p); _exit(0); }
	waitpid(c, &st, 0);
	return WIFSIGNALED(st) ? WTERMSIG(st) : 0;
}
static void rd1(char *p) { if (*(volatile char *)p == 99) _exit(1); }
static void wr1(char *p) { *(volatile char *)p = 1; }

static int denied_proc(void)	/* /proc refuses a denied page: a read must not return memory that is not the program's */
{
	char *p = anon(PG, PROT_READ | PROT_WRITE), *lo, b[8], nm[32]; int fd;
	memset(p, 0x5a, PG);
	if (mprotect(p, PG, PROT_NONE)) return 1;
	lo = mmap((caddr_t)0x00100000, PG, PROT_NONE, MAP_PRIVATE | MAP_FIXED, zfd, 0);
	if (lo == (char *)-1) return 2;
	sprintf(nm, "/proc/%05d", (int)getpid());
	if ((fd = open(nm, O_RDONLY)) < 0) return errno == EACCES ? 0 : 3;
	lseek(fd, (long)p, 0);
	if (read(fd, b, 8) != -1) return 4;
	lseek(fd, (long)lo, 0);
	if (read(fd, b, 8) != -1) return 5;
	close(fd);
	if (sig_of(rd1, p) != SIGSEGV) return 6;
	if (sig_of(wr1, p) != SIGSEGV) return 7;
	return 0;
}

static int rd_ok;
static void rd2(char *p) { rd_ok = *(volatile char *)p; if (rd_ok != 7) _exit(1); }
static int writeonly(void)	/* a read of a write-only page always succeeds: file, zero fill, a copy, a page out */
{
	char *p, *z, b[4]; int fd;
	file("wo", 2, 7);
	if ((fd = open(work, O_RDONLY)) < 0) return 1;
	p = mmap((caddr_t)0, 2 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	if (p == (char *)-1) return 2;
	close(fd);
	if (mprotect(p, 2 * PG, PROT_WRITE)) return 3;
	if (sig_of(rd2, p)) return 4;
	sprintf(work, "%s/vmr.wo2", dir);
	if ((fd = open(work, O_RDWR | O_CREAT | O_TRUNC, 0666)) < 0) return 5;
	if (write(fd, p + PG, 4) != 4) return 6;		/* a copyin from it */
	lseek(fd, 0L, 0);
	if (read(fd, b, 4) != 4 || b[0] != 7) return 7;
	close(fd); unlink(work);
	p[0] = 9;
	if (p[0] != 9) return 8;
	z = anon(PG, PROT_WRITE);
	if (*(volatile char *)z != 0) return 9;			/* zero fill */
	return 0;
}

static void tas1(char *p) { __asm__ __volatile__ ("tas %0@" : : "a" (p) : "memory", "cc"); }
static void cas1(char *p) { int o = 0, v = 1; __asm__ __volatile__ ("casl %0,%1,%2@" : "=d" (o) : "d" (v), "a" (p), "0" (o) : "memory", "cc"); }
static int rmw(void)	/* tas and cas: refused on a read-only page; a page first touched by one, or shared by fork, must work */
{
	char *r = anon(PG, PROT_READ), *w = anon(2 * PG, PROT_READ | PROT_WRITE); pid_t c; int st;
	if (sig_of(tas1, r) != SIGSEGV) return 1;
	if (sig_of(cas1, r) != SIGSEGV) return 2;
	tas1(w);			/* first touched by a tas */
	if (((unsigned char *)w)[0] != 0x80) return 3;
	cas1(w + PG);			/* by a cas */
	if (*(int *)(w + PG) != 1) return 4;
	if ((c = fork()) == 0) {	/* shared with the child: a copy on write under each */
		alarm(10);
		((unsigned char *)w)[1] = 0;
		tas1(w + 1);
		_exit(((unsigned char *)w)[1] == 0x80 ? 0 : 5);
	}
	tas1(w + 2);
	if (((unsigned char *)w)[2] != 0x80) return 6;
	waitpid(c, &st, 0);
	return st ? 7 : 0;
}

static int rt_n;
static void rt_h(int sig, siginfo_t *si, void *uc)
{
	if (si == 0) _exit(7);
	rt_n++;
	if (mprotect((caddr_t)((long)si->si_addr & ~(long)(PG - 1)), PG, PROT_READ | PROT_WRITE)) _exit(8);
}
static int repair_twice(void)	/* a handler with siginfo repairs a store across two denied pages, one page a call */
{
	struct sigaction sa; char *p = anon(2 * PG, PROT_NONE); volatile long *q = (volatile long *)(p + PG - 2);
	memset(&sa, 0, sizeof sa); sa.sa_flags = SA_SIGINFO; sa.sa_handler = (void (*)())rt_h;
	if (sigaction(SIGSEGV, &sa, 0)) return 1;
	*q = 0x11223344;
	if (*q != 0x11223344) return 2;
	return rt_n >= 1 ? 0 : 3;
}

static int denied_copies(void)	/* a regular file: /dev/null never touches the buffer */
{
	char *p = anon(PG, PROT_NONE), *x; int fd;
	sprintf(work, "%s/vmr.den", dir);
	if ((fd = open(work, O_RDWR | O_CREAT | O_TRUNC, 0666)) < 0) return 1;
	if (write(fd, "0123456789abcdef0123456789abcdef", 32) != 32) return 2;
	lseek(fd, 0L, 0);
	if (write(fd, p, 16) != -1 || errno != EFAULT) return 3;
	lseek(fd, 0L, 0);
	if (read(fd, p, 16) != -1 || errno != EFAULT) return 4;
	x = anon(PG, PROT_READ | PROT_WRITE);
	if (mprotect(x, PG, PROT_EXEC)) return 5;
	lseek(fd, 0L, 0);
	if (read(fd, x, 16) != -1 || errno != EFAULT) return 6;
	close(fd); unlink(work);
	return 0;
}

static int execonly(void)	/* execute-only: runs, a write is refused; the whole mapping, then one page of two */
{
	char *p = anon(PG, PROT_READ | PROT_WRITE), *q = anon(2 * PG, PROT_READ | PROT_WRITE);
	*(unsigned short *)p = 0x4e75;
	*(unsigned short *)q = 0x4e75;
	if (mprotect(p, PG, PROT_EXEC)) return 1;
	if (mprotect(q, PG, PROT_EXEC)) return 2;
	if (sig_of(rts_at, p)) return 3;
	if (sig_of(rts_at, q)) return 4;
	if (sig_of(wr1, p) != SIGSEGV) return 5;
	if (sig_of(wr1, q) != SIGSEGV) return 6;
	wr1(q + PG);			/* its neighbour still writes */
	return 0;
}

/* a mark no literal holds, so that finding it in the file means the page itself was written */
static void markup(char *d, int c) { int i; for (i = 0; i < 4; i++) d[i] = "vmr-"[i]; for (i = 4; i < 8; i++) d[i] = c; for (i = 8; i < 11; i++) d[i] = 'x' + i; }
static int markin(char *b, int c) { char m[11]; markup(m, c); return !memcmp(b, m, 11); }

static int denied_core(void)	/* good pages on both sides of a denied one reach the file; the denied page's does not */
{
	int st, fd, n, a = 0, b = 0, d = 0, i; pid_t c; char nm[300]; static char buf[PG];
	sprintf(nm, "%s/core", dir); unlink(nm);
	if ((c = fork()) == 0) {
		char *m = anon(3 * PG, PROT_READ | PROT_WRITE);
		memset(m, 0, 3 * PG);
		markup(m, 'A'); markup(m + PG, 'D'); markup(m + 2 * PG, 'B');
		if (mprotect(m + PG, PG, PROT_NONE)) _exit(1);
		chdir(dir);
		*(volatile int *)0x7ffe0000 = 1;
		_exit(2);
	}
	waitpid(c, &st, 0);
	if (!WIFSIGNALED(st)) return 1;
	if (!WCOREDUMP(st)) return 2;
	if ((fd = open(nm, O_RDONLY)) < 0) return 3;
	while ((n = read(fd, buf, PG)) > 0)
		for (i = 0; i + 11 <= n; i += 2) {
			if (markin(buf + i, 'A')) a = 1;
			if (markin(buf + i, 'B')) b = 1;
			if (markin(buf + i, 'D')) d = 1;
		}
	close(fd); unlink(nm);
	return a ? (b ? (d ? 6 : 0) : 5) : 4;
}

static void timing(void)
{
	struct tms t; clock_t a, b; int i, n = 2000; char *p; long hz = sysconf(_SC_CLK_TCK);
	p = anon(n * PG, PROT_READ | PROT_WRITE);
	a = times(&t);
	for (i = 0; i < n; i++) p[i * PG] = 1;
	b = times(&t);
	printf("timing: %d zero-fill write faults, %ld us each\n", n, (long)(b - a) * (1000000L / hz) / n);
	munmap(p, n * PG);
	p = anon(n * PG, PROT_READ);
	a = times(&t);
	for (i = 0; i < n; i++) if (p[i * PG] == 77) break;
	b = times(&t);
	printf("timing: %d zero-page read faults, %ld us each\n", n, (long)(b - a) * (1000000L / hz) / n);
	munmap(p, n * PG);	/* the cases after this dump core, under a 1 MiB limit */
}

static void one(char *name, int (*f)(void), int limit)
{
	int st, r; pid_t c;
	printf("%-16s ", name); fflush(stdout);
	if ((c = fork()) == 0) { alarm(limit); _exit(f()); }
	waitpid(c, &st, 0);
	r = WIFEXITED(st) ? WEXITSTATUS(st) : 200 + WTERMSIG(st);
	if (r) fails++;
	printf(r == 0 ? "PASS\n" : "FAIL %d\n", r); fflush(stdout);
}

int main(int ac, char **av)
{
	if (ac > 1) dir = av[1];
	zfd = open("/dev/zero", O_RDWR);
	one("cow-after-fork", cow, 30);
	one("private-file", privfile, 30);
	one("shared-file", sharedfile, 30);
	one("stack-growth", stack, 60);
	one("exec-shared", execs, 120);
	one("mprotect", mprot, 90);
	one("kernel-copies", copies, 60);
	one("rmw", rmw, 60);
	one("proc-breakpoint", bpt, 30);
	one("core-dump", core, 60);
	timing();
	one("denied-proc", denied_proc, 60);
	one("denied-copies", denied_copies, 60);
	one("exec-only", execonly, 60);
	one("write-only", writeonly, 60);
	one("repair-twice", repair_twice, 60);
	one("denied-core", denied_core, 60);
	if (fails) printf("VMREGRESS FAIL %d\n", fails); else printf("VMREGRESS PASS\n");
	return fails;
}
