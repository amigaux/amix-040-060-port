/* kinfotest.c -- check /dev/kinfo's device semantics on the box (docs/contracts/KINFO.md).
 * usage: kinfotest [node]        (default /dev/kinfo)
 * Reads the whole record, then checks: the magic, the version and length, the check word (all
 * longwords sum to zero), read at an lseek(2) offset equals the same bytes of the whole read, a
 * read at the length returns 0, write(2) fails with EPERM.  Prints KINFOTEST PASS or FAIL.
 * Builds with the native cc: cc -o kinfotest kinfotest.c                                      */
#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define KIF1	0x4B494631L

static unsigned char rec[4096];

static unsigned long
be32(p)
unsigned char *p;
{
	return (unsigned long) p[0] << 24 | (unsigned long) p[1] << 16 | (unsigned long) p[2] << 8 | p[3];
}

int
main(argc, argv)
int argc;
char **argv;
{
	char *node = argc > 1 ? argv[1] : "/dev/kinfo";
	unsigned char part[16];
	unsigned long sum, len;
	int fd, n, i, bad = 0;

	if ((fd = open(node, O_RDONLY)) < 0) {
		perror(node);
		return 2;
	}
	n = read(fd, (char *) rec, sizeof rec);
	printf("read %d bytes\n", n);
	if (n < 12 || be32(rec) != KIF1) {
		printf("FAIL: no KIF1 magic\n");
		return 1;
	}
	len = be32(rec + 4) & 0xFFFF;
	printf("version %lu length %lu\n", be32(rec + 4) >> 16, len);
	if (len != (unsigned long) n) {
		printf("FAIL: read %d bytes, the record says %lu\n", n, len);
		bad++;
	}
	for (sum = 0, i = 0; i + 4 <= n; i += 4)
		sum += be32(rec + i);
	printf("longword sum 0x%lx\n", sum);
	if (sum != 0) {
		printf("FAIL: the longwords do not sum to zero\n");
		bad++;
	}
	if (read(fd, (char *) part, sizeof part) != 0) {
		printf("FAIL: a read at the end did not return 0\n");
		bad++;
	}
	if (lseek(fd, 528L, 0) != 528L || read(fd, (char *) part, 12) != 12) {
		printf("FAIL: lseek 528 + read 12\n");
		bad++;
	} else {
		for (i = 0; i < 12 && part[i] == rec[528 + i]; i++)
			;
		printf("at 528: fast %lu chip %lu modules %lu\n", be32(part), be32(part + 4), be32(part + 8));
		if (i != 12) {
			printf("FAIL: the bytes at offset 528 differ from the whole read\n");
			bad++;
		}
	}
	if (lseek(fd, (long) len, 0) != (long) len || read(fd, (char *) part, 1) != 0) {
		printf("FAIL: a read at offset length did not return 0\n");
		bad++;
	}
	close(fd);
	if ((fd = open(node, O_WRONLY)) < 0)
		printf("open for writing: errno %d\n", errno);
	else {
		errno = 0;
		n = write(fd, "x", 1);
		printf("write: %d errno %d\n", n, errno);
		if (n != -1 || errno != EPERM) {
			printf("FAIL: write did not fail with EPERM\n");
			bad++;
		}
		close(fd);
	}
	printf("KINFOTEST %s\n", bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
