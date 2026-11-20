| hat_exec040.s -- 040 override of hat_exec (stock orig 0xb6f20, GLOBAL T): drop the old address space's
| translations of the exec stack image; move nothing.
|
| THE CALL.  exec builds the new stack image in the CURRENT address space, in the hole execstk_addr finds
| (the first one at or above 0x80000000), copies the arguments out into it (faulting its pages in through
| segvn, so the old as gets live leaf PTEs), and as_exec then moves the segment to the new as and calls
| hat_exec(oas, ostka, stksz, nas, nstka, hatflag).  Stock hat_exec moves the image's page tables to the
| new as and clears them in the old one (030 code, unported).  The pages belong to the segment's anon
| map, so the new as rebuilds the same translations by demand fault; only the old ones must go.
|
| WHY NOT A NO-OP (ISSUE-125).  From 2026-07-15 this was `return 0`, on the reasoning that relvm tears the
| old as down right after.  Under vfork it does not: the old as is the parent's and survives, keeping
| valid PTEs at ostka that point at the child's stack frames.  The next vfork child's exec builds its
| image at the same ostka; its copyout meets those PTEs, takes no fault and writes its arguments into the
| earlier child's live stack page (seen as child A's argv turning into child B's strings, then A dying).
| Stock's move was replaced in the first place because its unported steal path orphans live 040 PTEs
| under memory pressure (ISSUE-10 chain II, docs/contracts/HAT-EXEC-AUDIT.md); unloading through the
| ported hat_unload needs no allocation, so that hazard stays gone.
|
| THE UNLOAD.  hat_unload(seg, va, size, flags) reads only seg->s_as (+12) and the as's root (+20), so a
| zeroed stand-in seg on the stack carries oas.  flags 0 unmaps only: it clears each leaf PTE, carries
| the R/M bits into the page, unlinks the page's mapping entry and frees the leaf table once empty; it
| frees no page.  Its flushmmu after each PTE is a pflusha, so no ATC entry for ostka outlives it; the
| CPU runs on oas here (the exec'ing process's own as, or under vfork the parent's).  A freed root
| (as+20 = 0) makes hat_unload a no-op.  Returns 0, as before; stock's other arguments go unused.
| --weaken-symbol hat_exec.

	.text
	.globl	hat_exec
hat_exec:
	linkw	%fp,&-24		| fp@(-24): a struct seg stand-in, s_as at +12
	clrl	%fp@(-24)
	clrl	%fp@(-20)
	clrl	%fp@(-16)
	movel	%fp@(8),%fp@(-12)	| s_as = oas
	clrl	%fp@(-8)
	clrl	%fp@(-4)
	movel	%fp@(16),%d0		| stksz
	beqs	Lhx_done
	clrl	%sp@-			| flags 0: unmap only
	movel	%d0,%sp@-		| size
	movel	%fp@(12),%sp@-		| ostka
	pea	%fp@(-24)		| the stand-in seg
	jsr	hat_unload
	lea	%sp@(16),%sp
Lhx_done:
	clrl	%d0			| return 0
	unlk	%fp
	rts
	.balign	4			| pad section to a 4-byte multiple (bss placement guard)
