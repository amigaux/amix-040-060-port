/* isp61neg.c -- the negative half of the vector-61 acceptance.
 *
 * Spec: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md, "negative test".
 *
 * isp61test.c/isp61ea.c prove the handler emulates what it claims.  This proves it declines
 * everything else -- the half that keeps a partial implementation from silently producing
 * wrong arithmetic.
 *
 * RE-POINTED 2026-08-29.  The original instruction was a register-source 64-bit MULU.L, which
 * the 2026-08-09 EA widen turned into an EMULATED (Dn) form -- so the decline path had had no
 * live falsifier since then.  The instruction is now a 64-bit DIVIDE (DIVU.L #2,%d1:%d0, see
 * isp61neg_asm.s), which is outside the accepted multiply family and stays declined: the unit
 * discriminates on the OPWORD (0x4c7c is the divide group, not the 0x4c00 multiply group) and
 * never reaches the EA decode.
 *
 * EXPECTED, real 68060:
 *     the process is KILLED (signal 9) before printing SURVIVED
 *     isp61_entry_n        +1
 *     isp61_unsupported_n  +1
 *     isp61_ok_n           +0, every other failure counter +0
 *     console: "SIGKILL sent to pid N (.../isp61neg) because of vector 0xF4"
 *
 * EXPECTED, 68040: hardware executes the divide, prints SURVIVED with remainder:quotient =
 * 00000000:80000000 (2^32 / 2 = 2^31), exits 0, every isp61_* delta ZERO.
 *
 * So "it printed SURVIVED" is a PASS on the 040 and a FAILURE on the 060.  Read the counters
 * either way: a decline that does not increment isp61_unsupported_n would mean the handler
 * declined for the wrong reason (bad frame, non-user, trace).
 *
 * usage: isp61neg
 */

#include <stdio.h>

extern void isp61_neg();

main(argc, argv)
int argc;
char **argv;
{
	unsigned long r[2];

	r[0] = 0xdeadbeefL;
	r[1] = 0xdeadbeefL;

	printf("isp61neg: 64-bit DIVU.L #2,%%d1:%%d0 (.word 0x4c7c,0x0401,0x0000,0x0002)\n");
	printf("  060 expects: SIGKILL here, entry_n +1, unsupported_n +1, ok_n +0\n");
	printf("  040 expects: SURVIVED rem:quot = 00000000:80000000, every isp61_* delta 0\n");
	printf("about to execute...\n");
	fflush(stdout);

	isp61_neg(r);

	printf("ISP61NEG SURVIVED  rem:quot = %08lx:%08lx\n", r[0], r[1]);
	printf("ISP61NEG-RESULT SURVIVED (correct on a 68040, FAILURE on a 68060)\n");
	fflush(stdout);
	exit(0);
}
