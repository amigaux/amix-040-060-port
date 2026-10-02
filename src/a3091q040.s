| a3091q040.s -- keep the A3091 start queue consistent across disconnect and reselect
| (2026-10-02).  Driver-line port of amix-a4091's a3091.c.patch, second half (be2f5e3, the
| start-queue lifecycle); the first half of that patch, the chip-RAM bounce, is not carried.
|
| THE QUEUE.  a3091.c keeps the units waiting for the chip on a singly linked start queue
| (starthead/starttail, linked through the unit's first word).  `uqueue(up)` appends a unit
| and, on an empty queue, calls `startany()`; `startany()` pops the head when the DFA is IDLE
| and starts the head unit's first command.  struct unit is 16 bytes: next +0, comhead +4,
| comtail +8, the saved transfer count +0xc..+0xe (amiga/alien/a3091.c, struct unit; the
| `asll #4` in a3091queue confirms the stride in this binary).
|
| THE DEFECT, three shapes of one broken invariant ("linked on the start queue XOR active on
| the chip"):
|   * The reselect path (DFA case 3, also entered from case 2 after it re-queues the unit whose
|     selection the reselection pre-empted) resumes the reselecting unit and never removes it
|     from the start queue.  When that unit was linked there -- in particular when it is the
|     very unit case 2 just re-queued -- it is now active AND queued.
|   * `uqueue` clears the unit's link and appends it without asking whether it is already on
|     the queue, so re-queueing a linked unit cuts the queue at that unit and strands every
|     unit behind it.
|   * Once such a unit's command chain drains, its stale queue entry survives; the next
|     `startany` pops it and builds a command from a null comhead -- a wild DMA.
| Only real disconnect/reselect traffic reaches any of this.  amix-a4091 found it by reading
| the interrupt path (2026-08-07), and the fix there is source.  Here a3091.c is a binary, so
| the same three pieces are wrappers reached by relocation retargets (src/patch_a3091_queue.py):
|
|   a3091q_uqueue    the four `jsr uqueue` sites      0xcfbe 0xd1b4 0xd1d4 0xd2ea
|                    refuses to link a unit that is already linked; otherwise the stock body.
|                    There is no room for amix-a4091's membership flag in a stock struct, so
|                    membership is a walk of the queue (at most SDUNITS = 8 links).
|   a3091q_startany  the two `jsr startany` sites     0xd002 (in uqueue) 0xd356 (the IDLE tail)
|                    when IDLE, drops head entries whose comhead has drained, then the stock
|                    body.  Defence in depth: with the other two pieces nothing should be
|                    dropped, and a3q_drop counts it if something is.
|   a3091q_resume    the reconnect re-arm site        0xd21a
|                    unlinks the resuming unit from the start queue, then tail-jumps to what
|                    that site called before this pass: Antti's B2 dma_a3091_startdma_reconn
|                    (src/dma_cache040.s), with the stack exactly as case 3 built it.
|
| NOT GUARDED: src/a3091dbg040.s's own recovery path calls a3091_uqueue and a3091_startany by
| name.  Those are the stock bodies and stay so; that path runs only after the driver has
| declared the controller dead.
|
| A/B.  a3q_on = 1 (the default) runs the three pieces; 0 makes every wrapper a plain tail-jump
| to the stock body, so the control kernel differs from the fixed one by that word alone
| (patch_a3091_queue.py --off stamps it).
|
| COUNTERS.  a3q_magic first, then: a3q_dbl (re-queues refused), a3q_unq (resumes that found
| the unit linked), a3q_drop (drained entries dropped), a3q_walkcap (a walk that met more than
| SDUNITS links: the queue is already corrupt -- MUST STAY 0).  On the emulator all four read 0:
| Amiberry's WD33C93 never disconnects (its intermediate-disconnect path is compiled out), so
| cases 2 and 3 never run there.  tools/test-a3091q.sh exercises the wrappers on qemu-m68k.
|
| Register use: d0/d1/a0/a1 only, which every call site already treats as clobbered.  Runs at
| the driver's own priority: from a3091intr (level 2) and from a3091queue under sd's spl, so
| the queue cannot move under a walk.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/a3091q040.s -o build/a3091q040.o
| Linked LAST by relink-040-a3091q.sh: the .balign 4 closes both section totals.

	.text

	.globl	a3091q_uqueue
a3091q_uqueue:				| entry: sp@(4) = up
	tstl	a3q_on
	beqs	Lu_stock
	movel	%sp@(4),%d0
	moveal	a3091_starthead,%a0
	moveq	&9,%d1			| SDUNITS links, plus one
Lu_walk:
	cmpal	&0,%a0
	beqs	Lu_stock		| end of the queue: not linked
	cmpal	%d0,%a0
	beqs	Lu_dup
	moveal	%a0@,%a0		| next
	subql	&1,%d1
	bnes	Lu_walk
	addql	&1,a3q_walkcap		| a cycle or a corrupt link: leave it to the stock body
	bras	Lu_stock
Lu_dup:
	addql	&1,a3q_dbl		| already linked: linking again would cut the queue here
	rts
Lu_stock:
	jmp	a3091_uqueue

	.globl	a3091q_startany
a3091q_startany:			| no arguments
	tstl	a3q_on
	beqs	Ls_stock
	tstl	a3091_istate
	bnes	Ls_stock		| not IDLE: the stock body returns at once
	moveq	&9,%d1
Ls_head:
	moveal	a3091_starthead,%a0
	cmpal	&0,%a0
	beqs	Ls_stock
	tstl	%a0@(4)			| comhead
	bnes	Ls_stock		| a live head: the stock body starts it
	movel	%a0@,a3091_starthead	| drained: drop it, as the stock pop would, minus the start
	addql	&1,a3q_drop
	subql	&1,%d1
	bnes	Ls_head
	addql	&1,a3q_walkcap
Ls_stock:
	jmp	a3091_startany

	.globl	a3091q_resume
a3091q_resume:				| entry: sp@(4) = up, the reselecting unit (case 3)
	tstl	a3q_on
	beqs	Lr_go
	movel	%sp@(4),%d0
	subal	%a1,%a1			| prev = none
	moveal	a3091_starthead,%a0
	moveq	&9,%d1
Lr_walk:
	cmpal	&0,%a0
	beqs	Lr_go			| not linked: the normal shape, nothing to undo
	cmpal	%d0,%a0
	beqs	Lr_unlink
	moveal	%a0,%a1
	moveal	%a0@,%a0
	subql	&1,%d1
	bnes	Lr_walk
	addql	&1,a3q_walkcap
	bras	Lr_go
Lr_unlink:
	cmpal	&0,%a1
	bnes	Lr_mid
	movel	%a0@,a3091_starthead	| it was the head
	bras	Lr_tail
Lr_mid:
	movel	%a0@,%a1@		| prev->next = up->next
Lr_tail:
	cmpal	a3091_starttail,%a0
	bnes	Lr_counted
	movel	%a1,a3091_starttail	| it was the tail: prev is (0 if the queue is now empty)
Lr_counted:
	clrl	%a0@			| its own link: off the queue now
	addql	&1,a3q_unq
Lr_go:
	jmp	dma_a3091_startdma_reconn
	.balign 4

	.data
	.balign 4
	.globl	a3q_magic
a3q_magic:
	.long	0x41335121		| "A3Q!" -- static: proves the address
	.globl	a3q_on
a3q_on:
	.long	1			| 1 = the three pieces run; 0 = plain tail-jumps (control)
	.globl	a3q_dbl
a3q_dbl:
	.long	0			| re-queues of an already linked unit, refused
	.globl	a3q_unq
a3q_unq:
	.long	0			| resumes that found the unit on the start queue
	.globl	a3q_drop
a3q_drop:
	.long	0			| drained head entries dropped by startany
	.globl	a3q_walkcap
a3q_walkcap:
	.long	0			| MUST STAY 0: a walk met more than SDUNITS links
	.balign 4
