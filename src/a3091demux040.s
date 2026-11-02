| a3091demux040.s -- ISSUE-53: separate the A3091 interrupt SOURCES before the WD's
| status register is read.
|
| THE DEFECT.  a3091intr's whole admission test is two conditions: the unit's device pointer
| must be non-null, and ISTR bit 4 must be set.  If either fails the handler returns; if both
| hold it waits for CIP to clear and then reads the WD's status register SS.  There is no
| third test, and nothing between the ISTR read and the SS read narrows what raised the line.
|
| SDMAC ISTR bit 4 is INT_P, and INT_P is an AGGREGATE: the WD33C93A's own request
| (INTS, bit 6), the SDMAC's end-of-process (E_INT, bit 5), and the FIFO under/over-run
| errors all raise it.  So an interrupt that the SCSI controller never asked for is
| admitted as a controller event and dispatched on `SS` -- a register the data sheet
| defines only for a read that follows an asserted WD interrupt.  atab[IDLE][8] then
| returns DEAD, from which AMIX has no path back, and the machine needs a power cycle.
| Four captures on 2026-08-26, across three kernels, all with head=0 dmaon=0 segstate=0
| on units[6].  See docs/A3091-WEDGE-CAPTURED-260826.md and the audit it cites,
| amix-kernel-analysis/vm-map/A3091-SPURIOUS-COMPLETION-AUDIT.md.
|
| NetBSD's sys/arch/amiga/dev/ahsc.c (ahsc_dmaintr) and Linux's drivers/scsi/a3000.c
| (a3000_intr) both put the boundary this driver is missing between "which source
| interrupted" and "read WD status".  Two independent implementations for the same gate
| array; neither reads the WD unless ISTR.INTS says the WD asked.
|
| WHAT THIS DOES.  One snapshot of ISTR at entry -- before anything else, and the only one
| used for classification -- then:
|
|     INT_P clear ............ count, return exactly as the stock body would
|     error source present ... count, print (rate-limited), delegate.  FAIL-STOP KEPT
|     INTS set ............... delegate; afterwards ack a residual E_INT with CINT
|     E_INT alone ............ CINT, count, return WITHOUT reading SS or touching the DFA
|     INT_P with no source ... count, print, delegate.  FAIL-STOP KEPT
|
| Only the fourth line changes what the machine does, and only for a source that is
| PROVEN not to be the WD.  Everything else reaches the stock body unchanged.  That
| restriction is the whole design: the audit shows why the tempting one-byte alternative
| (atab[IDLE][8] -> no-op) is unsafe, because a target that disconnects leaves its request
| on the unit's comhead while istate returns to IDLE, so a GENUINE 0x16 at IDLE is a
| state/status mismatch worth stopping for, not noise.
|
| THE RACE, AND WHY THE PURE-E_INT ARM RE-READS.  INTS is a level indication of the WD's
| INTRQ pin.  The WD can assert it between our snapshot and the CINT.  NetBSD accepts that
| window and relies on INT_P re-asserting; this re-reads ISTR after the CINT and delegates
| if INTS has appeared, which closes it and counts how often it happened
| (a3w_eint_then_ints).  Cheap, and it removes the one way consuming an E_INT could lose a
| real completion.
|
| HOW IT IS REACHED.  int2_tbl is an array of function pointers in .data; the level-2
| dispatcher (amiga/ml/ttrap.s, p2int) walks it and `jsr`s every entry.  src/patch_a3091_intr.py
| retargets the ONE relocation for the a3091 slot, exactly as patch_a3091_dma.py and
| patch_segdev_ops.py do elsewhere.  a3091intr stays a strong global and stays callable by
| name, so no weakening and no --add-symbol alias are needed for it.
|
| CONTRACT, from p2int.
|   * The dispatcher pushes a fake USP and a pointer to it, so sp@(4) at our entry is a
|     `struct pcb *`.  a3091intr declares no parameters and its disassembly never touches
|     %fp@(8) -- checked over the whole body, 0xd0e0..0xd409 -- so delegating with a plain
|     `jsr` is safe even though it shifts that argument.
|   * The return value is DISCARDED: p2loop does `bra p2loop` and never inspects %d0.  The
|     stock body is C void.  So this returns nothing meaningful either.
|   * %a2 holds the walking table pointer ACROSS the jsr, so it must come back intact.  It
|     is callee-saved anyway; this saves %d2 and %a2 and touches no other non-scratch
|     register.
|
| WHAT IT COUNTS (since 2026-11-02 only the anomalies; the per-interrupt classification
| census that proved the mechanism cost every level-2 interrupt on every machine, A3091 or not):
|   a3w_other    -- 0.  A nonzero value is a source with no recovery contract yet; the entry
|                   snapshot is in a3w_other_istr and the first four print
|   a3w_allones  -- 0 on a healthy machine.  See ISSUE-58: nonzero means ISTR read back as
|                   all ones, which is a read that did not reach the chip rather than a
|                   source.  Read a3w_allones_re with it: a plausible second read says the
|                   register was fine and the bus was not.
|
| a3w_consume IS A LIVE A/B.  1 (the default) consumes a pure E_INT; 0 delegates it to the
| stock body.  kpoke flips it without a reboot.

	.text
	.globl	a3091intr_demux
a3091intr_demux:
	moveml	%d2/%a2,%sp@-		| %a2 = p2int's table cursor.  Both callee-saved.

	movel	a3091_device,%d0
	beqw	Law_nodev		| the stock body's first test, and its first return
	moveal	%d0,%a2

	clrl	%d2
	movew	%a2@(30),%d2		| THE snapshot.  device->istr, one read, before
					| anything else can change what it says
	cmpil	&0x0000ffff,%d2		| ISSUE-58: a read that did not land, not a source.
	beqw	Law_allones		| Tested BEFORE the OR below, so the census stays
					| a census -- see the counter's own comment.

	btst	&4,%d2			| INT_P -- the same gate, unchanged
	beqw	Law_notours

	movel	%d2,%d0
	andil	&0x010c,%d0		| INTX(8) | UE_INT(3) | OE_INT(2)
	bnew	Law_other		| an error source: no recovery contract, so fail-stop

	btst	&6,%d2			| INTS -- did the WD actually ask?
	beqw	Law_noints

| --- the WD asked.  Hand it to the stock body, then clean up a DMA event that rode in
|     with it, so the next interrupt is not a pure E_INT we have to reason about. ---
	jsr	a3091intr		| the stock body (no parameters, see above)
	movew	%a2@(30),%d0		| residual E_INT after the handler ran?
	btst	&5,%d0
	beqw	Law_out
	movew	&1,%a2@(26)		| CINT
	braw	Law_out

| --- INT_P without INTS.  E_INT alone is the audit's candidate; anything else is a
|     source we cannot name and must not swallow. ---
Law_noints:
	btst	&5,%d2
	beqw	Law_other
	tstl	a3w_consume
	bnes	Law_consume
	jsr	a3091intr		| the stock body (no parameters, see above)
	braw	Law_out
Law_consume:
	movew	&1,%a2@(26)		| CINT: the SDMAC's own latched event, acknowledged
					| without reading SS and without touching the DFA
	movew	%a2@(30),%d0		| did the WD assert while we were doing that?
	btst	&6,%d0
	beqw	Law_out
					| yes -- deliver it rather than wait for the level
	jsr	a3091intr		| the stock body (no parameters, see above)
	braw	Law_out

| --- an error or unclassified source.  Loud, and still fail-stop: the stock body decides,
|     exactly as it does today.  The print is capped so a storm cannot bury the console. ---
Law_other:
	addql	&1,a3w_other
	movel	%d2,a3w_other_istr
	movel	a3w_other_pr,%d0
	cmpil	&4,%d0
	bccs	Law_other_go
	addql	&1,a3w_other_pr
	movel	%d2,%sp@-
	pea	La3w_m1
	jsr	printf
	addql	&8,%sp
Law_other_go:
	jsr	a3091intr		| the stock body (no parameters, see above)
	braw	Law_out

| --- ISSUE-58: ISTR read back as all ones.  That is not a register value -- a real error
|     sets its own bit, not every bit including 15-9, which float on this hardware -- so it
|     is a read that did not reach the chip.  Counted apart from a3w_other so that a genuine
|     error source is still visible if one ever occurs, and READ AGAIN immediately: if the
|     second read is plausible, the register was fine and the bus read glitched.  The unit
|     already re-reads this register in the Law_wd path, so this is not a new kind of access.
|     Still fail-stop: the stock body decides, exactly as before. ---
Law_allones:
	addql	&1,a3w_allones
	clrl	%d0
	movew	%a2@(30),%d0		| the second read, taken as soon as possible
	movel	%d0,a3w_allones_re	| ... and latched whatever it says
	cmpil	&0x0000ffff,%d0
	bnes	Law_allones_pr
	addql	&1,a3w_allones_reff	| the second read was all ones too
Law_allones_pr:
	movel	a3w_allones_pr,%d1	| its own cap: an all-ones storm must not hide a
	cmpil	&4,%d1			| genuine a3w_other line, nor the reverse
	bccs	Law_allones_go
	addql	&1,a3w_allones_pr
	movel	%d0,%sp@-		| printf(fmt, first, second) -- args right to left
	movel	%d2,%sp@-
	pea	La3w_m2
	jsr	printf
	lea	%sp@(12),%sp		| addq only reaches 8; lea is the idiom for 12
Law_allones_go:
	jsr	a3091intr		| the stock body (no parameters, see above)
	braw	Law_out

Law_notours:
Law_nodev:
Law_out:
	moveml	%sp@+,%d2/%a2
	rts

	.balign	4

	.data
	.even
La3w_m1:
	.asciz	"a3091demux: unclassified istr=%x\n"
	.even
La3w_m2:
	.asciz	"a3091demux: istr all ones, reread=%x\n"
	.even
	.balign	4			| .asciz + .even can leave this 2 mod 4; the counter
					| block below is longwords and every tool that
					| computes offsets into it deserves better than luck
| --- counters, in reading order.  Magic first, as everywhere in this port. ---
	.globl	a3w_magic
a3w_magic:
	.long	0x41335721		| "A3W!" -- STATIC: proves the address
	.globl	a3w_consume
a3w_consume:
	.long	1			| 1 = consume a pure E_INT; 0 = delegate it (A/B)
	.globl	a3w_other
a3w_other:
	.long	0			| MUST STAY 0: error or unnameable source
	.globl	a3w_other_istr
a3w_other_istr:
	.long	0			| entry snapshot of the last unclassified one
	.globl	a3w_other_pr
a3w_other_pr:
	.long	0			| console lines spent on the above; capped at 4
| --- ISSUE-58, appended at the END so no existing offset moves (the a3d block gained its
|     last two counters the same way on 2026-08-27) ---
	.globl	a3w_allones
a3w_allones:
	.long	0			| ISTR read back 0xffff: a read that did not land
	.globl	a3w_allones_re
a3w_allones_re:
	.long	0			| the immediate second read of the last such
	.globl	a3w_allones_reff
a3w_allones_reff:
	.long	0			| ... of which the second read was all ones too
	.globl	a3w_allones_pr
a3w_allones_pr:
	.long	0			| console lines spent on the above; capped at 4
	.balign	4
