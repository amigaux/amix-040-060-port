| segvn_prot040.s -- restore SVR4's per-page permission check in segvn_faultpage.
|
| THE DEFECT (2026-08-06).  Linked AMIX segvn_faultpage reads the per-page protection and
| then walks straight into the fault body without ever testing it:
|
|     ac042: tstb %a4@(2)          svd->pageprot ?
|     ac04a: <switch on rw>        the protchk computation, whose result is never used
|     ac06a: bfextu %a1@,0,4,%d2   load vpage->vp_prot
|     ac070: braw ac07a            -> the fault body, unconditionally
|
| Every SVR4 reference rejects the access here.  Both of them select a single permission bit
| from the fault type -- read, write or execute, with every other case falling back to all
| three -- and then FAIL the fault with FC_PROT when that bit is absent from the page's own
| vp_prot.  The rejection is the whole point of the switch: the value it computes exists only
| to be tested against vp_prot on the next line.
|     3B2      seg_vn.c:1074-1095
|     USL SVR4.2   seg_vn.c:1169-1190
|
| That the compiler emitted a switch whose result is dead is itself the evidence: the selected
| bit is computed and then discarded, so the test that consumed it was dropped from the source
| rather than optimised away -- an optimiser that could see the value was unused would have
| removed the computation too.
|
| WHAT IT COSTS.  A denied write enters the COW/revalidation body, the mapping is reloaded
| READ-ONLY, and as_fault returns 0.  The instruction restarts into the same violation.  On
| the 060 that was measured as x60_last_afret = 0 with x60_last_psr2 = 0x800; on the 040 the
| retry recurses until the kernel stack is gone:
|
|     PANIC: KERNEL FAULT psw=0x2000, pc=0x80AE1D4 (as_fault+0xcc), vector=0x2
|     kernel stack full of ktraps -> k_trap -> usrxmemflt
|
| So any program that mprotects PART of a mapping read-only and then writes it takes the
| machine down.  Measured with test-tools/protfault.c case B on 68040-260806-02 -- an aligned
| write, no page crossing, on a 68040, i.e. with no 060 code reachable at all.  Case A (whole
| segment protected) passes on the same kernel because segvn_fault@0xac46a still performs the
| segment-wide check.  docs/SEGVN-PAGEPROT-PANIC-260806.md.
|
| NOT CPU-GATED, deliberately.  This is a generic VM defect present in stock AMIX (Codex reports
| the function's first 0x60 bytes are byte-identical to vanilla stand/unix), and it breaks the
| 040 and the 060 identically.  Gating it on cputype would leave the 040 broken.
|
| CONTRACT, every field read from the linked binary AND the vanilla headers, none assumed:
|   segvn_faultpage(seg, addr, off, ..., vpage, ..., rw, ...)   -- AMIX's seg_ops.fault takes
|     NO hat argument (vm/seg.h), and the prologue confirms the slots:
|       fp@(8)  -> d3 = seg     and d3@(28) = seg->s_data  (struct seg: lock,base,size,as,
|                                                           next,prev,ops = 28)
|       fp@(24) -> d7 = vpage   (bfextu %d7@,0,4 = vp_prot)
|       fp@(40) -> d6 = rw      (compared against 3 = S_EXEC, the switch bound)
|   struct segvn_data: mon_t lock (2) -> pageprot @2, prot @3   (vm/seg_vn.h + %a4@(2)/%a4@(3))
|   struct vpage: vp_prot is the FIRST 4-bit field -> the TOP nibble of the byte (m68k bitfields
|     are MSB-first, which is why the stock code uses bfextu offset 0 width 4)
|   PROT_READ 1, PROT_WRITE 2, PROT_EXEC 4 (sys/mman.h); S_READ 1, S_WRITE 2, S_EXEC 3 (vm/seg.h)
|   FC_PROT 4 (vm/faultcode.h) -- and segvn_fault's own segment-wide path returns exactly
|     `moveq #4,%d0`, so the value is confirmed twice.
|
| THE RULE (ISSUE-116).  Effective protection p = the page's vp_prot when the segment has per-page
| protections, else svd->prot.
|     F_SOFTLOCK                       passes, as stock.  /proc reads a denied page with it (prusrio:
|                                      F_SOFTLOCK, S_READ) and segvn_lockop locks one (S_OTHER).
|     p has no bit                     FC_PROT.  segvn_fault@0xac46a tests only a write under F_PROT, so a
|                                      PROT_NONE segment reached the body and restarted for ever.
|     S_WRITE and no PROT_WRITE in p   FC_PROT, at F_INVAL too: 0xac46a tests (prot & 3) == 1, so PROT_EXEC
|                                      alone passed it and a write restarted for ever.  The 68040's SSW RW and
|                                      the 68060's FSLW W are defined for every access, fetches included.
|     anything else                    passes.  The hardware cannot refuse a read of a write-only page or a
|                                      fetch of an execute-only one, and no caller passes S_EXEC: a fetch
|                                      arrives as S_READ, so testing the selected bit, as the references do,
|                                      refused to run an mprotect(PROT_EXEC) page.
|
| SHAPE.  A tail-call wrapper: no stack frame, so the argument block and return address stay
| exactly where the original expects them and control simply falls through with `jmp`.  d0/d1/a0
| are scratch in this ABI and the original reloads every argument itself, so nothing is saved.
| Since sp@(0) is the return address, argument N sits at sp@(4N): type is arg 8, rw arg 9
| (segvn_fault@0xac6a2 pushes them last-first from its own type and rw).

	.text
	.globl	segvn_faultpage
segvn_faultpage:
	moveq	&2,%d0
	cmpl	%sp@(32),%d0		| type == F_SOFTLOCK?
	beqw	Lsp_pass
	moveal	%sp@(4),%a0		| a0 = seg              (arg1)
	moveal	%a0@(28),%a0		| a0 = svd = seg->s_data
	tstb	%a0@(2)			| svd->pageprot: per-page protections present?
	bnes	Lsp_page
	moveb	%a0@(3),%d0		| no: svd->prot
	bras	Lsp_have
Lsp_page:
	moveal	%sp@(20),%a0		| a0 = vpage            (arg5)
	movel	%a0,%d0
	beqw	Lsp_pass		| defensive: pageprot set but no vpage array -> do not
					| invent a verdict; let the stock body decide
	moveb	%a0@,%d0		| the vpage byte: vp_prot is its TOP nibble
	lsrb	&4,%d0
Lsp_have:
	andib	&7,%d0
	beqs	Lsp_deny		| no permission at all
	btst	&1,%d0			| PROT_WRITE?
	bnes	Lsp_pass
	moveq	&2,%d1
	cmpl	%sp@(36),%d1		| rw == S_WRITE?        (arg9)
	bnes	Lsp_pass
Lsp_deny:
	moveq	&0,%d1
	movel	%sp@(8),segvn_prot_last_addr	| arg2 = the denied address
	movel	%d1,segvn_prot_last_prot	| 0 here by construction; kept so a future
						| reader sees the tested value, not a claim
	addql	&1,segvn_prot_n
	moveq	&4,%d0			| FC_PROT -- the return SVR4 specifies
	rts
Lsp_pass:
	jmp	segvn_faultpage_orig	| tail call: frame, args and return address untouched

	.data
	.globl	segvn_prot_magic
segvn_prot_magic:
	.long	0x53564e21		| "SVN!" -- read this before trusting any address below
	.globl	segvn_prot_n
segvn_prot_n:
	.long	0			| accesses REJECTED with FC_PROT.  Every one of these
					| used to fall through and retry forever.
	.globl	segvn_prot_last_addr
segvn_prot_last_addr:
	.long	0			| last denied address
	.globl	segvn_prot_last_prot
segvn_prot_last_prot:
	.long	0			| the vp_prot & protchk value that triggered it
	.balign	4
