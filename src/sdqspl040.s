| sdqspl040.s -- sdqueue at IPL 2 at least: the a3091 first-use hang (amix-dlm C2-4 version 24 section 18).
|
| dd.c, sdpart.c and ct.c call sdqueue at sdspl() (spl2).  scsi.c's gsioctl, the /dev/scsi pass-through
| (kbootset inquiry), calls it at spl0.  When that is the stock a3091 driver's first command, its
| initialize() resets the WD33C93 with level 2 open: the reset's interrupt preempts the poll, a3091intr
| reads SS 0x01 while IDLE, prints "a3091: 0x1 0 0x0" and marks the controller DEAD, and the queued
| command never completes.  A first command that arrives at spl2 (a dd read or write) does not hang.
|
| This takes the strong `sdqueue`; the stock body stays at .text 0xd6f6 as `sdqueue_orig`
| (relink-040.sh).  It raises to IPL 2 only when called below it -- the DDI allows sdqueue at any level
| but 6, so it never lowers -- calls the stock body, and restores SR only if it raised.  The SR values
| are the stock spl2's (0x2200).  The same rule as the 68030 line's sd.c (amix kernel/k30).
| Returns what the stock body returns, in d0 and a0.  SDQ_SPL=0 builds without it.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c sdqspl040.s -o build/sdqspl040.o

	.text
	.globl	sdqueue
sdqueue:
	movel	%d2,%sp@-
	movew	%sr,%d2			| the caller's SR
	movew	%d2,%d1
	andiw	&0x0700,%d1
	cmpiw	&0x0200,%d1
	bccs	Lsq_call		| already at IPL 2 or above: leave it
	movew	&0x2200,%sr		| spl2
Lsq_call:
	movel	%sp@(8),%sp@-		| cp
	jsr	sdqueue_orig
	addql	&4,%sp
	movew	%d2,%d1
	andiw	&0x0700,%d1
	cmpiw	&0x0200,%d1
	bccs	Lsq_ret			| it was not raised here: nothing to restore
	movew	%d2,%sr			| splx
Lsq_ret:
	movel	%sp@+,%d2
	moveal	%d0,%a0			| SVR4 m68k: the result rides in a0 too, as the stock body leaves it
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
