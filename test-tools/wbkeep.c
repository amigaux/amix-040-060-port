/*
 * wbkeep.c -- does a store that faults land once a SIGSEGV handler repairs the mapping and returns?
 *
 * On a 68040 the faulted store is not re-run: it waits in the access-error frame's write-back
 * slots, and the kernel completes it (src/wb040.s, src/wbkeep040.s).  On the 68030 and 68060 the
 * instruction is re-run.  Either way a handler that repairs and returns must find the store done.
 *
 *   mprotect cases: the second of two pages is read-only; the store faults; the handler makes it
 *     writable and returns.  byte, word, long, a misaligned long across the page boundary, and a
 *     misaligned word across it.
 *   brk case: a long stored one page past the break; the handler grows the break (sh's malloc does
 *     this), or on the 68040 the kernel grows it without a signal (src/hgfault040.s); then the same
 *     store followed by the program's own small sbrk, which must not take the stored page back.
 *   longjmp case (-j N): N stores into a read-only page whose handler longjmps out instead of
 *     returning.  The store must NOT land (the context was abandoned), and the kernel's record of
 *     it is freed with the process's address space: read wbk_live before and after the run.
 *
 * Prints one line per case and "WBKEEP PASS" or "WBKEEP FAIL n"; exit status = failures.
 * Build: m68k-cbm-sysv4-gcc -m68040 -O -o wbkeep wbkeep.c   (or the guest's /usr/ccs/bin/cc)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <setjmp.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/mman.h>

static char *base;		/* two pages */
static long pg;
static volatile int nsig, mode;	/* mode 0: mprotect repair, 1: grow the break, 2: longjmp out */
static char *brkwant;
static jmp_buf jb;

static void
handler(int sig)
{
	signal(sig, handler);		/* SVR4 signal(): reset to SIG_DFL on delivery */
	nsig++;
	if (nsig > 5) {
		printf("  handler called %d times: the store never completes\n", nsig);
		exit(99);
	}
	if (mode == 0)
		mprotect(base + pg, pg, PROT_READ | PROT_WRITE);
	else if (mode == 1)
		while ((char *)sbrk(0) <= brkwant)
			sbrk(pg);
	else
		longjmp(jb, 1);
}

static int fails;

static void
check(const char *what, int ok)
{
	printf("  %-34s %s (handler %d)\n", what, ok ? "ok" : "FAILED", nsig);
	if (!ok)
		printf("    read back: %08lx %08lx %08lx %08lx at the second page +0 +0x10 +0x20 +0x40\n",
		    *(unsigned long *)(base + pg), *(unsigned long *)(base + pg + 0x10),
		    *(unsigned long *)(base + pg + 0x20), *(unsigned long *)(base + pg + 0x40));
	if (!ok)
		fails++;
}

static void
arm(void)
{
	mprotect(base, 2 * pg, PROT_READ | PROT_WRITE);
	memset(base, 0, 2 * pg);
	mprotect(base + pg, pg, PROT_READ);
	nsig = 0;
}

int
main(int argc, char **argv)
{
	int fd;
	volatile int i, nj = 0;
	char *p2;
	unsigned char b[4];

	if (argc > 2 && strcmp(argv[1], "-j") == 0)
		nj = atoi(argv[2]);
	pg = sysconf(_SC_PAGESIZE);
	fd = open("/dev/zero", O_RDWR);
	base = mmap(0, 2 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	if (fd < 0 || base == (char *)-1) {
		perror("mmap /dev/zero");
		return 100;
	}
	signal(SIGSEGV, handler);
	signal(SIGBUS, handler);
	p2 = base + pg;
	printf("wbkeep: page %ld, pages at %lx\n", pg, (long)base);

	mode = 0;
	arm(); *(volatile unsigned char *)(p2 + 0x10) = 0x5a;
	check("byte", nsig >= 1 && p2[0x10] == 0x5a);
	arm(); *(volatile unsigned short *)(p2 + 0x20) = 0x1234;
	check("word", nsig >= 1 && *(unsigned short *)(p2 + 0x20) == 0x1234);
	arm(); *(volatile unsigned long *)(p2 + 0x40) = 0xdeadbeefUL;
	check("long", nsig >= 1 && *(unsigned long *)(p2 + 0x40) == 0xdeadbeefUL);
	arm(); *(volatile unsigned long *)(p2 - 2) = 0xcafef00dUL;
	memcpy(b, p2 - 2, 4);
	check("misaligned long across the page", nsig >= 1 && b[0] == 0xca && b[1] == 0xfe && b[2] == 0xf0 && b[3] == 0x0d);
	arm(); *(volatile unsigned short *)(p2 - 1) = 0xabcd;
	check("misaligned word across the page", nsig >= 1 && (unsigned char)p2[-1] == 0xab && (unsigned char)p2[0] == 0xcd);

	mode = 1;
	{
		char *e = sbrk(0);
		brkwant = (char *)(((long)e + pg - 1) & ~(pg - 1)) + 8;
		nsig = 0;
		*(volatile unsigned long *)brkwant = 0x600dcafeUL;
		/* the 68040 kernel grows the break itself for a store one page past it (no signal) */
		check("long past the break", *(unsigned long *)brkwant == 0x600dcafeUL);
		/* the same, then the program's own small sbrk: a grow the program was not told of
		   must not be taken back by its next brk (sh's arena sentinel lives there) */
		e = sbrk(0);
		brkwant = (char *)(((long)e + pg - 1) & ~(pg - 1)) + 16;
		nsig = 0;
		*(volatile unsigned long *)brkwant = 0x5eed1e55UL;
		sbrk(64);
		check("long past the break, then sbrk", *(unsigned long *)brkwant == 0x5eed1e55UL);
	}

	mode = 2;
	for (i = 0; i < nj; i++) {
		arm();
		if (setjmp(jb) == 0)
			*(volatile unsigned long *)(p2 + 0x80) = 0x0badf00dUL;
		if (i == 0 || i == nj - 1)
			check("longjmp out: the store does not land", nsig == 1 && *(unsigned long *)(p2 + 0x80) == 0);
		else if (!(nsig == 1 && *(unsigned long *)(p2 + 0x80) == 0))
			fails++;
	}
	if (nj)
		printf("  longjmp out x%d done\n", nj);

	if (fails)
		printf("WBKEEP FAIL %d\n", fails);
	else
		printf("WBKEEP PASS\n");
	return fails;
}
