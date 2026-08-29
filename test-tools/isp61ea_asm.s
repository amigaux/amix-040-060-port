| isp61ea_asm.s -- one 64-bit multiply per ACCEPTED addressing mode, in the exact encoding,
| for the widened vector-61 unit (2026-08-09).
|
| WHY HAND-ENCODED.  gcc emits mulsl/mulul #imm32 only as a magic-multiply for division by a
| constant, and it never emits the (d16,An)/(An)/Dn source forms on purpose.  Asking the
| compiler for them would measure the compiler.  Every instruction under test is therefore a
| literal .word sequence, so what runs is exactly what isp61_060.s must decode.
|
| WHY A NEGATIVE DISPLACEMENT IS IN HERE.  wolf3d's site is muls.l (12,%a6),%d1:%d2 -- a
| POSITIVE d16.  The unit sign-extends the displacement, and nothing in wolf3d would notice if
| that were wrong.  ea_d16neg reads the operand at (-4,%a6) instead, so a missing `extl` turns
| it into a read 65532 bytes ABOVE the frame: a wrong answer or a fault, never a pass.
|
| WHY THE PC ADVANCE IS TESTED WITHOUT A TEST FOR IT.  The four modes are 8, 6, 4 and 4 bytes
| long.  If the unit advances the PC by the wrong amount, the instruction after the multiply is
| entered at the wrong offset -- the store of the result, here -- so a correct 64-bit product
| coming back from every mode IS the length check.
|
| Each entry point:  void ea_xxx(unsigned long a, unsigned long b, unsigned long out[2])
|                    a = Dl (multiplicand), b = the source operand, out[0]=hi out[1]=lo
| a6@(8) = a,  a6@(12) = b,  a6@(16) = out.  d1:d0 is Dh:Dl throughout, so the extension word
| is 0x0401 unsigned / 0x0c01 signed:  Dl=d0 (bits 14-12 = 0), S = bit 11, SIZE = bit 10 = 1,
| Dh=d1 (bits 2-0 = 1).

	.text

| ---- 7/4  #imm32, opword 0x4c3c, 8 bytes.  The form F2 already accepted. ----
	.globl	ea_imm_u
ea_imm_u:
	link	%a6,#-8
	movel	%a6@(8),%d0
	.word	0x4c3c,0x0401,0x9abc,0xdef0	| mulul #0x9abcdef0,%d1:%d0
	braw	Lea_store

	.globl	ea_imm_s
ea_imm_s:
	link	%a6,#-8
	movel	%a6@(8),%d0
	.word	0x4c3c,0x0c01,0x9abc,0xdef0	| mulsl #0x9abcdef0,%d1:%d0
	braw	Lea_store

| ---- 5/n  (d16,An), opword 0x4c2e for A6, 6 bytes.  wolf3d's own form. ----
	.globl	ea_d16pos
ea_d16pos:
	link	%a6,#-8
	movel	%a6@(8),%d0
	.word	0x4c2e,0x0c01,0x000c		| mulsl %a6@(12),%d1:%d0  <- b, in place
	braw	Lea_store

	.globl	ea_d16neg
ea_d16neg:
	link	%a6,#-8
	movel	%a6@(12),%d0
	movel	%d0,%a6@(-4)			| the operand goes BELOW the frame pointer
	movel	%a6@(8),%d0
	.word	0x4c2e,0x0c01,0xfffc		| mulsl %a6@(-4),%d1:%d0  <- d16 = -4
	braw	Lea_store

	.globl	ea_d16u
ea_d16u:
	link	%a6,#-8
	movel	%a6@(8),%d0
	.word	0x4c2e,0x0401,0x000c		| mulul %a6@(12),%d1:%d0
	braw	Lea_store

| ---- 2/n  (An), opword 0x4c10 for A0, 4 bytes ----
	.globl	ea_an
ea_an:
	link	%a6,#-8
	movel	%a6@(12),%d0
	movel	%d0,%a6@(-4)
	leal	%a6@(-4),%a0
	movel	%a6@(8),%d0
	.word	0x4c10,0x0c01			| mulsl %a0@,%d1:%d0
	braw	Lea_store

| ---- 0/n  Dn, opword 0x4c03 for D3, 4 bytes ----
	.globl	ea_dn
ea_dn:
	link	%a6,#-8
	movel	%d3,%sp@-			| d3 is callee-saved and is the source here
	movel	%a6@(12),%d3
	movel	%a6@(8),%d0
	.word	0x4c03,0x0c01			| mulsl %d3,%d1:%d0
	moveal	%a6@(16),%a1
	movel	%d1,%a1@
	movel	%d0,%a1@(4)
	movel	%sp@+,%d3
	unlk	%a6
	rts

| ---- a DECLINED mode, to prove the fallback still refuses instead of guessing.
| 3/n (An)+ would have to write A0 back, so the unit counts it and lets nullvect kill us.
| The caller runs this in a child: dying IS the expected result.
	.globl	ea_postinc
ea_postinc:
	link	%a6,#-8
	movel	%a6@(12),%d0
	movel	%d0,%a6@(-4)
	leal	%a6@(-4),%a0
	movel	%a6@(8),%d0
	.word	0x4c18,0x0c01			| mulsl %a0@+,%d1:%d0   <- expected: SIGKILL
	braw	Lea_store

| ================= 2026-08-29: the three remaining reachable source modes =================
| (xxx).L absolute (7/1), (d8,An,Xn) brief-indexed (6/n) and (d16,A7).  Same discipline as
| above: every operand sits at the EXACT effective address, and the slots a wrong EA would hit
| instead are poisoned with 0xdeadbeef -- so a mis-decoded index, scale, displacement or base
| comes back as a WRONG PRODUCT, never as a plausible one and never as a bare fault.

	.data
	.balign	4
ea_abs_lo:	.long	0xdeadbeef		| the longs bracketing the (xxx).L slot: an
ea_abs_slot:	.long	0			| absolute address off by one long reads poison
ea_abs_hi:	.long	0xdeadbeef

	.text
| ---- 7/1  (xxx).L absolute, opword 0x4c39, 8 bytes.  gcc emits this for every non-PIC global
| or static operand.  The 32-bit address is the two words after the multiply's extension word.
	.globl	ea_abs
ea_abs:
	link	%a6,#0
	movel	%a6@(12),%d0			| b
	movel	%d0,ea_abs_slot			| store b into the absolute slot
	movel	%a6@(8),%d0			| Dl = a
	.word	0x4c39,0x0401			| mulul ea_abs_slot,%d1:%d0  (unsigned)
	.long	ea_abs_slot			| the absolute effective address
	braw	Lea_store

| ---- 6/n  (d8,An,Xn) brief format, opword 0x4c30 for A0, 6 bytes.  gcc emits this for every
| variable-index array element.  b is placed at exactly A0 + d2.l*4 + 4; the rest of the buffer
| is poison, so a wrong index register, scale or displacement returns 0xdeadbeef-derived garbage.
	.globl	ea_index
ea_index:
	link	%a6,#-32
	movel	%d2,%sp@-			| d2 is callee-saved and is the index register here
	leal	%a6@(-32),%a0			| a0 = base of the poisoned buffer
	movel	#0xdeadbeef,%d0
	movel	%d0,%a0@(0)
	movel	%d0,%a0@(4)
	movel	%d0,%a0@(8)
	movel	%d0,%a0@(12)
	movel	%d0,%a0@(16)
	movel	%d0,%a0@(20)
	movel	%a6@(12),%d0			| b
	movel	%d0,%a0@(12)			| EA = A0 + (2 * 4) + 4 = A0 + 12
	moveq	#2,%d2				| index register d2 = 2
	movel	%a6@(8),%d0			| Dl = a
	.word	0x4c30,0x0c01,0x2c04		| mulsl (4,%a0,%d2.l*4),%d1:%d0  (signed)
	movel	%sp@+,%d2
	braw	Lea_store

| ---- 5/7  (d16,A7), opword 0x4c2f, 6 bytes.  A7 is the user stack pointer, which the kernel
| does NOT save in its 60-byte register block, so the unit must read it from the live USP.  b is
| pushed so it lands at (0,%sp); out is captured through the shifted arg offsets.  No frame is
| used -- a link register would move A7 and defeat the point.
	.globl	ea_d16a7
ea_d16a7:
	movel	%sp@(8),%d0			| b (arg1), sp-relative, before the push
	movel	%d0,%sp@-			| push b: it now sits at (0,%sp)
	movel	%sp@(8),%d0			| Dl = a (arg0, at sp@(8) after the 4-byte push)
	.word	0x4c2f,0x0401,0x0000		| mulul (0,%a7),%d1:%d0  (unsigned)
	moveal	%sp@(16),%a1			| out (arg2, at sp@(16) after the push)
	movel	%d1,%a1@			| out[0] = Dh
	movel	%d0,%a1@(4)			| out[1] = Dl
	addql	#4,%sp				| pop b
	rts

Lea_store:
	moveal	%a6@(16),%a1
	movel	%d1,%a1@			| out[0] = Dh = product bits 63-32
	movel	%d0,%a1@(4)			| out[1] = Dl = product bits 31-0
	unlk	%a6
	rts
