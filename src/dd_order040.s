| dd_order040.s -- dd.c completion ordering: issue the next command BEFORE iodone(), not
| after it (2026-09-27).
|
| THE DEFECT.  dd.c's interrupt completion (the file-static `ihandle`, stock .text 0xbfb6)
| finishes a buffer with iodone(bp) and only then calls startio(FIRST, dp) to issue the next
| command on the unit.  iodone() runs the buffer's b_iodone callback, and a chunked transfer's
| callback submits the next chunk through ddstrategy() synchronously -- which reaches startio()
| while the completion is still inside iodone().  ddstrategy starts the unit only when its queue
| head is empty, and c0a4 below has already advanced the head, so the resubmit issues the next
| command itself -- and then ihandle's own trailing call issues the head again: the same
| &dp->com issued twice.  The fix, which amix-z3660scsi carries at source on the 68030 line, is
| the order: issue next, then iodone.  It removes the double issue.  It does NOT change the
| recursion depth of a host that completes synchronously inside sdqueue (that depth equals the
| queue depth in either order; amix-z3660scsi bounds it with its own completion FIFO), and with
| such a host it runs iodone() for the later buffers before the earlier one.
|
| THE SITE, as linked (identical on every base of this line; stock prefix, never moved):
|
|     c0a4  dp->bhead = bp->next
|     c0aa  push bp
|     c0ac  jsr iodone             <- R_68K_32 iodone  @0xc0ae
|     c0b2  push dp                   (iodone's argument is not popped; unlk cleans up)
|     c0b4  push FIRST (0)
|     c0b6  jsr startio            <- R_68K_32 startio @0xc0b8
|     c0bc  restore; a0 = d0; unlk; rts     -- ihandle RETURNS startio's result
|
| and the error path shares the call at c0b6: it pushes dp and 2, then `braw c0b6`.  Nothing
| else branches into c0a4..c0b8 except through c0a4, and nothing outside ihandle branches in.
|
| THE FIRST ATTEMPT (docs/Z3660-KERNEL-FEASIBILITY-260731.md 5; the island dd_startio_first in
| src/z3660_glue040.s, still behind Z3660_DD_ORDER=1) retargeted only the `iodone` relocation and
| panicked before the banner.  After iodone returned, the stock `jsr startio` at c0b6 still ran,
| so with two or more buffers queued startio(FIRST, dp) ran twice per completion.  That is a
| HYPOTHESIS for the panic, not an established cause: that record leaves the cause open, and a
| double issue needs two queued buffers before the banner.  The other candidate -- that issuing
| before iodone is itself unsafe on the stock A3091 path -- this unit shares.  So the acceptance
| for this unit is a boot, not this argument (docs/DD-COMPLETION-ORDER.md).  This unit retargets
| BOTH tail relocations (src/patch_dd_order.py), so exactly one issue happens, before iodone, and
| the stock code between the two calls is kept byte for byte.
|
| THE TWO SHIMS.  No stock code is re-expressed; the error path is left exactly as it was.
|
|   dd_issue_first   replaces `jsr iodone` at c0ac.  Issues startio(FIRST, dp) first, keeps
|                    its result on its OWN stack across iodone -- no static, so a completion
|                    nested inside iodone (a synchronous driver completing from inside the
|                    resubmit) keeps its own value -- and returns that result in d0.
|   dd_startio_tail  replaces `jsr startio` at c0b6.  With FIRST it is on the completion path,
|                    whose issue already happened: it returns at once, and d0 is still the
|                    value dd_issue_first returned (c0b2/c0b4 are two pushes, neither touches
|                    d0), so ihandle returns whatever startio returned, as before (on an empty
|                    queue startio returns without setting d0, in stock and here).  Any other first
|                    argument (the error path's 2 = retry, or 1 = request sense, which this site
|                    never passes) tail-jumps into startio unchanged.
|
| Register use: d0/d1/a0/a1 only, which ihandle already treats as clobbered across both calls.
| a4 is dp at c0ac -- c0a4 has just written dp->bhead through it, and the stock code pushes a4
| as dp immediately after iodone -- and a4 is callee-saved, so startio and iodone preserve it.
|
| No timeout() deferral here or anywhere on this path: amix-z3660scsi completes synchronously
| through its own FIFO, because a timeout()-deferred completion was fatal for a stack-resident
| request (src/z3660.c in that repository, the completion comment).
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/dd_order040.s -o build/dd_order040.o
| Linked LAST by relink-040-dd.sh: the .balign 4 below closes both section totals.

	.text

	.globl	dd_issue_first
dd_issue_first:				| entry: sp@ = return (c0b2), sp@(4) = bp
	movel	%a4,%sp@-		| dp
	clrl	%sp@-			| FIRST
	jsr	startio
	addql	&8,%sp
	movel	%d0,%sp@-		| startio's result: ihandle returns it
	movel	%sp@(8),%sp@-		| bp, the argument dd.c pushed for iodone
	jsr	iodone
	addql	&4,%sp
	movel	%sp@+,%d0		| startio's result back in d0
	rts				| to c0b2, stack exactly as after the stock `jsr iodone`

	.globl	dd_startio_tail
dd_startio_tail:			| entry: sp@(4) = first argument, sp@(8) = dp
	tstl	%sp@(4)
	bnes	Ldd_tail_issue		| not FIRST: the error path, issue as stock does
	rts				| FIRST: issued before iodone; d0 carries that result
Ldd_tail_issue:
	jmp	startio
	.balign 4

	.data
	.balign 4
