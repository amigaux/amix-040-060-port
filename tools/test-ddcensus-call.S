| test-ddcensus-call.S -- host stub for tools/test-ddcensus.c: call dd_vtop_census the way dd's
| startio does, with startio's callee-saved %a3 (bp) and %d2 (block) loaded.
| long call_census(long va, long proc, void *bp, long block)
	.text
	.globl	call_census
call_census:
	moveml	%d2/%a3,%sp@-		| stack: d2 a3 ret va proc bp block
	moveal	%sp@(20),%a3
	movel	%sp@(24),%d2
	movel	%sp@(16),%sp@-		| proc
	movel	%sp@(16),%sp@-		| va
	jsr	dd_vtop_census
	addql	#8,%sp
	moveml	%sp@+,%d2/%a3
	rts
