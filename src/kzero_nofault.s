| kzero_nofault.s -- kzero() that does not panic when a page cannot be brought in.  (2026-10-30)
|
| THE CONTRACT.  SVR4's kzero(addr, len) is bzero with a fault catch: it returns 0, or -1 when
| a fault inside it cannot be resolved.  vm_pvn.c's pvn_vptrunc says why it calls kzero and
| not bzero: if the last page cannot be read in, the system must not panic.  In the stock 2.1c
| kernel `kzero` is a second name for bzero (both .text+0x302), so the catch is missing and an
| unresolvable fault in the zeroing loop is a KERNEL FAULT panic.  Callers: pvn_vptrunc,
| rwvp, spec_write -- all three ignore the return value, as SVR4's do.
|
| THE PANIC IT FIXES (grimoire quirk 90).  ftruncate (fcntl F_FREESP) -> ufs_space ->
| ufs_freesp -> ufs_itrunc -> pvn_vptrunc -> kzero.  A shrink to an unaligned length M inside
| the 8 KiB block that holds the old EOF N, past the 12 direct blocks: ufs_itrunc passes
| zbytes = 8192 - (M mod 8192), pvn_vptrunc zeroes through segkmap to the end of the block, and
| when that block ends past the page holding the old EOF (roundup(N, PAGESIZE) <
| roundup(N, 8192)) the loop stores into a page wholly beyond EOF that the fault path does not
| resolve: `PANIC: KERNEL FAULT ... pc=<load base>+0x32A (060) / +0x32C (030), vector 2`.
| Measured in emulation 2026-10-30 on both lines.  Nothing is lost by stopping there: the loop
| runs upward, so [M, end of the old-EOF page) -- the bytes that can ever be read again -- is
| already zero when the fault is taken.
|
| THE MECHANISM: the u_nofault landing pad.  u+0x374 is the stock catch word copyin, copyout,
| fubyte and friends arm (lfubyte: `movel &sf_fault,u+0x374`).  k_trap, for an access fault
| with the pad armed, saves and clears it, runs the resolver FIRST (userspace(frame) picks by
| the access's function code: a supervisor store such as this loop's -> krnxmemflt ->
| as_fault(&kas) -> segmap_fault -> VOP_GETPAGE), puts it back, and only when the resolver
| failed sets the frame's PC to the pad and rte's there with the trap-time registers and
| stack.  So a page inside the file that is merely not resident still faults in and the loop
| continues; only an unresolvable fault lands on Lkz_fail.  (k_trap .text+0x5a19e..0x5a222 in
| the stock image; src/wb040.s arms the same pad for its write-back replay.)
|
| WHOSE LANDING.  u_nofault is one scalar and k_trap only tests it for non-zero (the ISSUE-42
| Q3 audit of wb040).  Interrupts stay enabled here, so an unrelated kernel fault taken while
| it is armed -- an interrupt handler's -- would land on this pad too.  The pad accepts a
| landing only if the trap-time a2 equals the trap-time sp and the word on top of that stack is
| Lkz_ret, the return address of our jsr: both hold for a fault inside our bzero and not for
| another context's.  Anything else panics, as the unarmed kernel would have.  The owner is
| kept in registers, not in .data, because the resolver may sleep (VOP_GETPAGE) and another
| process may run kzero meanwhile; u_nofault itself is per process (the u-area).
|
| Not CPU-specific: 68000 instructions only, the stock bzero, the stock u-area offset and the
| stock k_trap.  The 68030 line can assemble this file unchanged.
|
| Registers: d2 holds the outer u_nofault value and a2 the stack bzero runs on; both are
| trap-time registers at the pad (bzero touches only d0/d1/a0/a1).

	.text
	.globl	kzero
kzero:
	movel	%d2,%sp@-
	movel	%a2,%sp@-
	addql	&1,kzr_calls
	movel	%sp@(16),%sp@-		| len
	movel	%sp@(16),%sp@-		| addr (sp moved by the push above)
	movel	u+0x374,%d2		| the outer u_nofault value
	lea	%sp@(-4),%a2		| the stack bzero runs on, once the jsr pushes Lkz_ret
	movel	&Lkz_fail,u+0x374	| arm
	jsr	bzero
Lkz_ret:
	movel	%d2,u+0x374		| disarm: the outer value back
	addql	&8,%sp
	moveq	&0,%d0
	moveal	%sp@+,%a2
	movel	%sp@+,%d2
	rts

| k_trap could not resolve a store of the loop.  sp is bzero's: Lkz_ret on top, then the two
| arguments, then a2 and d2.  a0 is bzero's store pointer at the fault.
Lkz_fail:
	cmpl	%a2,%sp
	bnes	Lkz_alien
	cmpl	&Lkz_ret,%sp@
	bnes	Lkz_alien
	movel	%d2,u+0x374		| disarm first, before anything below can fault
	addql	&1,kzr_fail_n
	movel	%a0,kzr_last_addr
	lea	%sp@(12),%sp		| Lkz_ret and the two arguments
	moveq	&-1,%d0
	moveal	%sp@+,%a2
	movel	%sp@+,%d2
	rts

Lkz_alien:
	addql	&1,kzr_alien_n
	movel	%sp,%d0
	movel	%a2,%sp@-		| the a2 it came with
	movel	%d0,%sp@-		| the stack it came with
	pea	Lkz_amsg
	pea	3			| CE_PANIC
	jsr	cmn_err
	lea	%sp@(16),%sp		| not reached
	rts
	.balign	4

	.data
	.even
Lkz_amsg:
	.asciz	"kzero: u_nofault landing pad entered from a FOREIGN context sp=%x a2=%x"
	.balign	4
| Counter block.  Read kzr_magic first: if it is not "KZR!" the addresses are stale.
	.globl	kzr_magic
kzr_magic:
	.long	0x4b5a5221		| "KZR!"
| kzero entries: pvn_vptrunc, rwvp, spec_write.  Nonzero on any kernel that has written a file.
	.globl	kzr_calls
kzr_calls:
	.long	0
| Unresolvable faults caught: a kzero that stopped early and returned -1.
	.globl	kzr_fail_n
kzr_fail_n:
	.long	0
| bzero's store pointer at the last caught fault.
	.globl	kzr_last_addr
kzr_last_addr:
	.long	0
| Foreign landings (each one is a panic; the count survives in a dump).
	.globl	kzr_alien_n
kzr_alien_n:
	.long	0
	.balign	4
