| wbkeep040.s -- a 68040's pending write-backs kept across the signal of an unresolved user fault,
| and completed when the handler returns to the faulted context.
|
| On an access error the 68040 does not re-run the faulted store: its address, data and status sit
| in the format-7 frame's WB1-WB3 fields, and the kernel completes them (wb040.s, after as_fault
| resolved the page).  When the fault cannot be resolved the process gets a signal, and the frame,
| with the stores in it, is gone.  A handler that repairs the mapping and returns -- sh's malloc
| grows its arena this way -- resumes after a store that never happened.  The 68030 and 68060 re-run
| the faulting instruction instead, so there the store lands on the retry.
|
| wbk_save(frame, first)  usrxmemflt, the fault unresolved (first = 1) or a write-back's replay denied
|     (first = wbf_slot, the slots before it completed): keep WB<first>..WB3 of a format-7 frame taken
|     in user mode, keyed by the address space and the context the signal saves (the frame's USP at
|     +0 and PC at +66).  Returns 1 when it kept something (then nothing was dropped), else 0.
| restorecontext          setcontext's restore of a ucontext: when the registers it restored are a
|     kept context's (same address space, USP and PC), replay the kept write-backs through
|     wb040_replay on a synthetic frame, so its WB1 lane realignment and function-code handling apply
|     unchanged.  A replay that is denied again raises SIGSEGV and keeps the slots not yet done: the
|     handler is called again, as the re-run does on the 68030/68060.  Any other restore (a longjmp
|     out of the handler, another context) leaves the record alone.
| as_free                 the address space dies (exit, exec): its records go.
| sendsig                 a signal is delivered at a kept context.  The first is the signal of the fault.
|     A second means the first handler left without restoring that context (longjmp) and the program is
|     past the store, so the record goes; left there, this signal's return would replay an old store over
|     newer data.
|
| The table holds WBK_N records of WBK_SZ bytes: as, usp, pc, then the frame's bytes +76..+111 (SSW,
| WB3S, WB2S, WB1S, FA, WB3A, WB3D, WB2A, WB2D, WB1A, WB1D) as the CPU stacked them, with the valid
| bit cleared in every slot that is not to be replayed, then whether the signal went out and the real uid.
| Only write-backs with a user function code (1, 2) are kept.  The table is shared, and a record can stay
| until its process exits (a handler that leaves by longjmp, a signal ignored), so a real uid holds at most
| WBK_UIDMAX: one user can fill only that much and cannot make another user's stores drop.  A uid at its
| limit, or a full table, takes the faulting address space's own record whose signal has gone out, when the
| new fault has a store to keep; never another process's, whose handler may still be running or whose
| replay may be asleep with it.  Else the new store is dropped, as before this file, and counted.
|
| Frame layout (getuvpcb, prsetregs): usp at +0, d0-a6 at +4..+60, SR at +64, PC at +66, the
| format/vector word at +70; WB3S +78, WB2S +80, WB1S +82 (wb040.s).
|
| WBKEEP=0 builds without it (relink-040.sh).
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c wbkeep040.s -o build/wbkeep040.o

	.set	WBK_N, 32
	.set	WBK_SZ, 56
	.set	WBK_UIDMAX, 4
	.set	E_AS, 0
	.set	E_USP, 4
	.set	E_PC, 8
	.set	E_RAW, 12		| frame +76 .. +111
	.set	E_WB3S, 14		| frame +78
	.set	E_WB2S, 16		| frame +80
	.set	E_WB1S, 18		| frame +82
	.set	E_SENT, 48		| the fault's signal has gone out
	.set	E_UID, 52		| the faulting process's real uid
	.set	P_AS, 124		| proc->p_as
	.set	P_CRED, 16		| proc->p_cred (getuid)
	.set	CR_RUID, 12		| cred->cr_ruid (getuid)
	.set	P_PCB, 252		| restorecontext: prsetregs(curproc's +252, gregs); getuvpcb takes it

	.data
	.globl	wbk_tab, wbk_live, wbk_saved_n, wbk_replayed_n, wbk_refault_n, wbk_full_n, wbk_freed_n, wbk_stale_n, wbk_evict_n, wbk_cap_n
	.balign	4
wbk_tab:	.space	WBK_N*WBK_SZ
wbk_live:	.long	0		| records in the table now
wbk_saved_n:	.long	0		| records made
wbk_replayed_n:	.long	0		| records completed by a matching restorecontext
wbk_refault_n:	.long	0		| replays denied again (SIGSEGV, record kept)
wbk_full_n:	.long	0		| records dropped, the table full
wbk_freed_n:	.long	0		| records dropped with their address space
wbk_stale_n:	.long	0		| records dropped: a second signal at the kept context
wbk_evict_n:	.long	0		| records taken for the same address space's new store, the table full or the uid at its limit
wbk_cap_n:	.long	0		| records dropped, the uid at its limit
	.globl	wbk_inreplay
wbk_inreplay:	.long	0		| user replays in progress (usrxmemflt's and restorecontext's):
					| wb040.s's wbf_dropwarn stays quiet for a fault nested in one

	.text
| ---------------------------------------------------------------------------------------------
| Lwk_slot(a0 = status word address, d1 = first slot to keep, d0 = this slot): clear the word's
| valid bit unless slot >= first and its function code is a user one; d2 += 1 if kept.  Uses d0 only.
Lwk_slot:
	cmpl	%d1,%d0
	blts	Lwk_clear
	movew	%a0@,%d0
	btst	&7,%d0
	beqs	Lwk_done
	andiw	&7,%d0
	cmpiw	&1,%d0
	beqs	Lwk_keep
	cmpiw	&2,%d0
	beqs	Lwk_keep
Lwk_clear:
	bclr	&7,%a0@(1)
Lwk_done:
	rts
Lwk_keep:
	addql	&1,%d2
	rts

| ---------------------------------------------------------------------------------------------
	.globl	wbk_save
wbk_save:
	linkw	%fp,&0
	moveml	%d2-%d5/%a2-%a3,%sp@-
	moveal	%fp@(8),%a2		| the trap frame
	moveq	&0,%d0
	moveb	%a2@(70),%d0
	lsrb	&4,%d0
	cmpiw	&7,%d0
	bnew	Ls_ret			| not a 68040 access-error frame: nothing pending
	movew	%a2@(64),%d0
	btst	&13,%d0
	bnew	Ls_ret			| taken in supervisor mode: no user context to resume
	moveal	u+0x730,%a0
	movel	%a0@(P_AS),%d3		| d3 = curproc->p_as
	moveal	%a0@(P_CRED),%a0
	movel	%a0@(CR_RUID),%d4	| d4 = its real uid
	lea	wbk_tab,%a1
	subal	%a3,%a3			| a3 = the first free record
	moveq	&0,%d5			| d5 = live records of this uid
	moveq	&WBK_N-1,%d2
Ls_find:
	movel	%a1@(E_AS),%d0
	bnes	Ls_used
	tstl	%a3
	bnes	Ls_next
	moveal	%a1,%a3
	bras	Ls_next
Ls_used:
	cmpl	%a1@(E_UID),%d4
	bnes	Ls_ouid
	addql	&1,%d5
Ls_ouid:
	cmpl	%d3,%d0
	bnes	Ls_next
	movel	%a2@,%d0
	cmpl	%a1@(E_USP),%d0
	bnes	Ls_next
	movel	%a2@(66),%d0
	cmpl	%a1@(E_PC),%d0
	beqw	Ls_same			| the same context faulted again: refresh its record
Ls_next:
	lea	%a1@(WBK_SZ),%a1
	dbra	%d2,Ls_find
	moveq	&WBK_UIDMAX,%d0
	cmpl	%d0,%d5
	bges	Ls_full			| this uid at its limit
	tstl	%a3
	bnew	Ls_new
| The table is full, or this uid at its limit.  When this fault has a store to keep, take this address space's
| own record whose signal has gone out (a handler left it by longjmp, or this is a fault inside that handler);
| none, and the new store is dropped, counted.
Ls_full:
	movel	%fp@(12),%d1		| first slot to keep
	lea	%a2@(82),%a0		| WB1S, then WB2S and WB3S below it
	moveq	&1,%d0
Ls_any:
	cmpl	%d1,%d0
	blts	Ls_anyn
	movew	%a0@,%d2
	btst	&7,%d2
	beqs	Ls_anyn
	andiw	&7,%d2
	cmpiw	&1,%d2
	beqs	Ls_evs
	cmpiw	&2,%d2
	beqs	Ls_evs
Ls_anyn:
	subql	&2,%a0
	addql	&1,%d0
	cmpiw	&3,%d0
	bles	Ls_any
	braw	Ls_ret			| nothing to keep: nothing taken, nothing dropped
Ls_evs:
	lea	wbk_tab,%a1
	moveq	&WBK_N-1,%d2
Ls_ev:
	tstl	%a1@(E_SENT)
	beqs	Ls_evn
	cmpl	%a1@(E_AS),%d3
	bnes	Ls_evn
	cmpl	%a1@(E_UID),%d4
	beqs	Ls_evt
Ls_evn:
	lea	%a1@(WBK_SZ),%a1
	dbra	%d2,Ls_ev
	moveq	&WBK_UIDMAX,%d0
	cmpl	%d0,%d5
	blts	Ls_tfull
	addql	&1,wbk_cap_n
	braw	Ls_ret
Ls_tfull:
	addql	&1,wbk_full_n
	braw	Ls_ret
Ls_evt:
	moveal	%a1,%a3
	addql	&1,wbk_evict_n
	subql	&1,wbk_live		| counted again below
	bras	Ls_new
Ls_same:
	moveal	%a1,%a3
	subql	&1,wbk_live		| counted again below
Ls_new:
	lea	%a2@(76),%a0		| copy the frame's +76..+111 as stacked
	lea	%a3@(E_RAW),%a1
	moveq	&8,%d0
Ls_copy:
	movel	%a0@+,%a1@+
	dbra	%d0,Ls_copy
	movel	%fp@(12),%d1		| first slot to keep
	moveq	&0,%d2			| user write-backs kept
	lea	%a3@(E_WB1S),%a0
	moveq	&1,%d0
	bsrw	Lwk_slot
	lea	%a3@(E_WB2S),%a0
	moveq	&2,%d0
	bsrw	Lwk_slot
	lea	%a3@(E_WB3S),%a0
	moveq	&3,%d0
	bsrw	Lwk_slot
	tstl	%d2
	beqs	Ls_drop			| none to keep: the record stays free
	movel	%a2@,%a3@(E_USP)
	movel	%a2@(66),%a3@(E_PC)
	clrl	%a3@(E_SENT)
	movel	%d4,%a3@(E_UID)
	movel	%d3,%a3@(E_AS)		| last: the record is live from here
	addql	&1,wbk_live
	addql	&1,wbk_saved_n
	moveq	&1,%d0			| kept
	bras	Ls_out
Ls_drop:
	clrl	%a3@(E_AS)
Ls_ret:
	moveq	&0,%d0			| nothing kept: the caller reports the drop
Ls_out:
	moveml	%sp@+,%d2-%d5/%a2-%a3
	unlk	%fp
	rts

| ---------------------------------------------------------------------------------------------
| restorecontext(ucp): the stock body (restorecontext_orig), then the replay of a kept record whose
| context it has just restored.  fp@(-112) is the synthetic frame, fp@(-116)/(-120) the caller's
| DFC/SFC (wb040_replay sets DFC and leaves it), fp@(-124) the record, fp@(-156) a siginfo.
	.globl	restorecontext
restorecontext:
	linkw	%fp,&-156
	moveml	%d2-%d4/%a2-%a3,%sp@-
	movel	%fp@(8),%sp@-
	jsr	restorecontext_orig
	addqw	&4,%sp
	movel	%d0,%d4
	tstl	wbk_live
	beqw	Lr_ret
	moveal	u+0x730,%a0
	movel	%a0@(P_PCB),%sp@-	| what restorecontext hands prsetregs: curproc's +252,
	jsr	getuvpcb		| whose user frame the restore wrote
	addqw	&4,%sp
	moveal	%a0,%a3
	moveal	u+0x730,%a0
	movel	%a0@(P_AS),%d1
	lea	wbk_tab,%a1
	moveq	&WBK_N-1,%d2
Lr_find:
	cmpl	%a1@(E_AS),%d1
	bnes	Lr_next
	movel	%a3@,%d0
	cmpl	%a1@(E_USP),%d0
	bnes	Lr_next
	movel	%a3@(66),%d0
	cmpl	%a1@(E_PC),%d0
	beqs	Lr_hit
Lr_next:
	lea	%a1@(WBK_SZ),%a1
	dbra	%d2,Lr_find
	braw	Lr_ret
Lr_hit:
	movel	%a1,%fp@(-124)
	lea	%fp@(-112),%a2		| the synthetic format-7 frame
	moveal	%a2,%a0
	moveq	&27,%d0
Lr_zero:
	clrl	%a0@+
	dbra	%d0,Lr_zero
	moveb	&0x70,%a2@(70)
	lea	%a1@(E_RAW),%a0
	lea	%a2@(76),%a3
	moveq	&8,%d0
Lr_copy:
	movel	%a0@+,%a3@+
	dbra	%d0,Lr_copy
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%fp@(-116)
	.word	0x4e7a,0x0000		| movec %sfc,%d0
	movel	%d0,%fp@(-120)
	addql	&1,wbk_inreplay		| a denial in here is the handler's cue, not a dropped store
	jsr	wb040_replay		| a2 = frame; d0 = 0 all done, else denied at wbf_slot
	subql	&1,wbk_inreplay
	movel	%d0,%d2
	movel	%fp@(-116),%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	movel	%fp@(-120),%d0
	.word	0x4e7b,0x0000		| movec %d0,%sfc
	moveal	%fp@(-124),%a1
	tstl	%d2
	bnes	Lr_again
	clrl	%a1@(E_AS)
	subql	&1,wbk_live
	addql	&1,wbk_replayed_n
	braw	Lr_ret
Lr_again:
	addql	&1,wbk_refault_n	| keep the slots from the denied one on, signal again
	clrl	%a1@(E_SENT)
	movel	wbf_slot,%d1
	moveq	&0,%d2
	lea	%a1@(E_WB1S),%a0
	moveq	&1,%d0
	bsrw	Lwk_slot
	lea	%a1@(E_WB2S),%a0
	moveq	&2,%d0
	bsrw	Lwk_slot
	lea	%a1@(E_WB3S),%a0
	moveq	&3,%d0
	bsrw	Lwk_slot
	lea	%fp@(-156),%a0		| a siginfo from the nested verdict, as the fault's own signal has: psignal
	moveq	&7,%d0			| would leave an SA_SIGINFO handler a null pointer, and the re-run on
Lr_si:					| the 68030/68060 gives it the far page
	clrl	%a0@+
	dbra	%d0,Lr_si
	lea	%fp@(-156),%a0
	movel	wbf_signo,%d0
	bnes	Lr_sih
	moveq	&11,%d0			| nothing recorded
	movel	&2,wbf_code
Lr_sih:
	movel	%d0,%a0@		| si_signo
	movel	wbf_code,%a0@(4)	| si_code
	movel	wbf_fa,%d0
	bnes	Lr_sia
	movel	wbf_addr,%d0
Lr_sia:
	movel	%d0,%a0@(12)		| si_addr
	movel	%a0,%sp@-
	movel	u+0x730,%sp@-
	jsr	trapsig
	addql	&8,%sp
Lr_ret:
	movel	%d4,%d0
	moveml	%sp@+,%d2-%d4/%a2-%a3
	unlk	%fp
	moveal	%d0,%a0
	rts

| ---------------------------------------------------------------------------------------------
| sendsig(...): the stock body (sendsig_orig) after the record of the context being interrupted, if any,
| is marked or dropped.  The frame is u_ar0 (u+0x864), as sendsig_orig reads it: USP at +0, PC at +66.
	.globl	sendsig
sendsig:
	tstl	wbk_live
	beqs	Lg_go
	movel	%d2,%sp@-
	moveal	u+0x864,%a0
	moveal	u+0x730,%a1
	movel	%a1@(P_AS),%d0
	lea	wbk_tab,%a1
	moveq	&WBK_N-1,%d1
Lg_loop:
	cmpl	%a1@(E_AS),%d0
	bnes	Lg_next
	movel	%a0@,%d2
	cmpl	%a1@(E_USP),%d2
	bnes	Lg_next
	movel	%a0@(66),%d2
	cmpl	%a1@(E_PC),%d2
	bnes	Lg_next
	tstl	%a1@(E_SENT)
	bnes	Lg_stale
	movel	&1,%a1@(E_SENT)
	bras	Lg_done
Lg_stale:
	clrl	%a1@(E_AS)
	subql	&1,wbk_live
	addql	&1,wbk_stale_n
	bras	Lg_done
Lg_next:
	lea	%a1@(WBK_SZ),%a1
	dbra	%d1,Lg_loop
Lg_done:
	movel	%sp@+,%d2
Lg_go:
	jmp	sendsig_orig

| ---------------------------------------------------------------------------------------------
| as_free(as): drop the address space's records, then the stock body (as_free_orig).
	.globl	as_free
as_free:
	tstl	wbk_live
	beqs	Lf_go
	movel	%sp@(4),%d0
	lea	wbk_tab,%a0
	moveq	&WBK_N-1,%d1
Lf_loop:
	cmpl	%a0@(E_AS),%d0
	bnes	Lf_next
	clrl	%a0@(E_AS)
	subql	&1,wbk_live
	addql	&1,wbk_freed_n
Lf_next:
	lea	%a0@(WBK_SZ),%a0
	dbra	%d1,Lf_loop
Lf_go:
	jmp	as_free_orig
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
