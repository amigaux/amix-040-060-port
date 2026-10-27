| krnx_quiet040.s -- the kernel fault resolver's FAILEXIT line, off on a module kernel unless asked
| for (2026-10-27).
|
| src/krnxmemflt040.s prints "DBG krnxflt FAILEXIT w=.. va=.. rw=.. depth=.." with cmn_err(CE_WARN)
| whenever a kernel-mode fault is not resolved -- up to eight times a boot.  A driver's caught bprobe
| of an empty address is exactly that, so a release console shows it for nothing.  The base keeps the
| print (the static families, the debug lines); relink-040-dlm.sh retargets that one call onto
| krnx_cmn_err (src/patch_krnx_quiet.py), which calls cmn_err only while krnx_fail_print is nonzero.
| Poke krnx_fail_print to 1 for a hunt.  The stack is cmn_err's own: the caller pushed the arguments
| and pops them; this either tail-jumps into cmn_err or returns.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/krnx_quiet040.s -o build/krnx_quiet040.o

	.text
	.globl	krnx_cmn_err
krnx_cmn_err:
	tstl	krnx_fail_print
	beqs	Lkq_quiet
	jmp	cmn_err
Lkq_quiet:
	rts

	.data
	.balign	4
	.globl	krnx_fail_print
krnx_fail_print:
	.long	0			| patchable: 1 prints the FAILEXIT line again
