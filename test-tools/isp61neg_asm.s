| isp61neg_asm.s -- the NEGATIVE case for the 68060 vector-61 unit.
|
| Spec: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md, "negative test".
|
| RE-POINTED 2026-08-29.  The original negative case was a REGISTER-source 64-bit multiply
| (MULU.L %d1,%d2:%d0, .word 0x4c01,0x0402).  When this test was written (2026-08-06) the unit
| accepted only the immediate form, so a register source was genuinely declined -- but the
| 2026-08-09 EA widen ADDED the Dn source mode, and from that day the register-source multiply
| was EMULATED, not declined.  The negative case had been passing by being handled, which is no
| falsifier at all: the decline path had had no working test since 2026-08-09.  It is re-pointed
| here to an instruction that is genuinely outside the accepted family and always will be.
|
| The instruction below is a 64-bit DIVIDE:
|
|     DIVU.L #2,%d1:%d0        .word 0x4c7c,0x0401,0x0000,0x0002
|
|     opword 0x4c7c = 0x4c40 (long divide group) | EA 0x3c (7/4 = #imm32)
|     ext    0x0401: bits14-12 = Dq = 0 (%d0, quotient), bit11 = 0 (unsigned),
|                    bit10 = 1 (64-bit dividend Dr:Dq), bits2-0 = Dr = 1 (%d1, remainder)
|     imm32  0x00000002  (the divisor)
|     dividend = %d1:%d0 = 0x00000001:0x00000000 = 2^32
|
| The unit decodes the OPWORD first: 0x4c7c & 0xffc0 = 0x4c40, which is not 0x4c00, so it never
| reaches the EA decode -- it declines at the multiply/divide discriminator and counts
| isp61_unsupported_n.  The 68060 retired the 64-bit divide in hardware exactly as it retired
| the 64-bit multiply, so on real silicon this traps to vector 61; the compiler never emits it
| (long-long division routes through __udivdi3/__divdi3), which is why nothing has to emulate it.
|
| On a real 68060 it must:
|     isp61_entry_n        +1   (the handler is entered)
|     isp61_unsupported_n  +1   (and declines, by the opword, not by guess)
|     isp61_ok_n           +0   (nothing was emulated)
|   and the process dies of SIGKILL with a console "vector 0xF4" line.
|
| On a 68040 the hardware executes it: 2^32 / 2 = 2^31, quotient 0x80000000, remainder 0, the
| program prints its result and exits 0.  That asymmetry is the point: the same binary
| distinguishes the two CPUs.
|
| C ABI (K&R, stack): isp61_neg(out) -> sp@(4) = out
|     out@(0) = remainder(%d1), out@(4) = quotient(%d0)

	.text
	.globl	isp61_neg
isp61_neg:
	moveal	%sp@(4),%a0		| a0 = out  (nothing pushed: only d0/d1 are clobbered)
	movel	&1,%d1			| Dr = high dividend = 1
	movel	&0,%d0			| Dq = low dividend  = 0  -> dividend = 0x0000000100000000
	.word	0x4c7c,0x0401,0x0000,0x0002	| DIVU.L #2,%d1:%d0  -> q=%d0, r=%d1
	movel	%d1,%a0@		| out[0] = remainder (only reached on a 68040)
	movel	%d0,%a0@(4)		| out[1] = quotient  = 0x80000000
	rts
	.balign	4
