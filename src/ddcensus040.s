| ddcensus040.s -- DIAGNOSTIC ONLY: a census of disk requests whose buffer crosses a page, taken
| where the buffer's virtual address is still known (2026-10-03, P-15 DI-1 follow-up).
|
| NEVER IN A SHIPPING CHAIN.  relink-040-ddcensus.sh says so too; kerntools builds a separate
| diagnostic chain for the rig and the Bench.
|
| WHY HERE.  The host adapter is given ONE physical address per request (dd.c startio:
| com.addr = vtop(b_addr)) and moves the length linearly from it.  A buffer that crosses a page
| is right only if its second page's frame is the next frame.  The kernel's identity region
| (va < 0x40000000: DTT0, vtop040.s returns pa == va) is contiguous by construction; a kvseg buffer
| (va >= 0x40000000, sptalloc'd pages) need not be.  The Z3660 driver's own z3660_pagecross_n
| sees only the physical address and cannot tell the two apart.  At startio's vtop call both are
| known, so this is where the census goes.
|
| THE HOOK.  dd's startio calls vtop exactly once (.text 0xc108, relocation at 0xc10a); that one
| relocation is retargeted here (src/patch_ddcensus.py).  dd_vtop_census calls vtop with the same
| two arguments and returns its result unchanged, in d0 and a0.  What it reads besides its
| arguments are startio's callee-saved registers, unchanged on entry (verified by disassembly at
| 0xc0c8..0xc108 and asserted by the patcher):
|     %a3 = bp     b_bcount +0x20, b_edev +0x5c, B_READ = bit 0 of the byte at +3
|     %d2 = sdblkno(bp), the absolute block number of the request
| It writes nothing but its own counters and ring.  It uses d0/d1/a0/a1 only, which startio
| already treats as clobbered across the call.
|
| Every request through dd's startio is seen: buffer-cache I/O, gen_strategy/buf_breakup pieces and
| the raw path's amiga_dma_pageio pieces.  Not seen: dd's REQUEST SENSE (a separate vtop of the
| static per-unit sense buffer, identity region) and cdfs's own media reads (it calls sdqueue
| directly and refuses page-crossing buffers itself).
|
| COUNTERS (dcn_magic first, "DCN!" 0x44434E21; all .data, read with kmemdump/adb):
|   +0x00 dcn_magic     +0x04 dcn_on (1; 0 = plain pass-through)   +0x08 dcn_n (all requests)
|   +0x0C dcn_cross_id  crossers in the identity region (harmless by construction)
|   +0x10 dcn_cross_kv  crossers in kvseg (va >= 0x40000000)
|   +0x14 dcn_kv_scat   kvseg crossers whose second page is NOT the next frame -- THE HAZARD;
|                       the positive safety statement is "this stayed 0"
|   +0x18 dcn_ring_i    next ring slot (mod 16); the number of kvseg crossers recorded
|   +0x1C dcn_ring      16 entries x 32 bytes, kvseg crossers only:
|         +0 seq (dcn_n at the time)  +4 va  +8 pa  +12 pa2 (vtop of the next virtual page)
|         +16 len (b_bcount)  +20 block (sdblkno)  +24 b_edev  +28 flags: 1 = read, 4 = scattered
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/ddcensus040.s -o build/ddcensus040.o
| Linked LAST by relink-040-ddcensus.sh: the .balign 4 closes both section totals.

	.text

	.globl	dd_vtop_census
dd_vtop_census:				| sp@(4) va, sp@(8) proc; a3 = bp, d2 = block (startio's)
	movel	%sp@(8),%sp@-		| proc
	movel	%sp@(8),%sp@-		| va
	jsr	vtop
	addql	&8,%sp
	tstl	dcn_on
	beqw	Ldc_ret
	addql	&1,dcn_n
	movel	%sp@(4),%d1		| va
	andil	&0xfff,%d1
	addl	%a3@(32),%d1		| page offset + b_bcount
	cmpil	&0x1000,%d1
	blsw	Ldc_ret			| inside one page
	movel	%sp@(4),%d1
	cmpil	&0x40000000,%d1
	bccs	Ldc_kv			| unsigned >= 0x40000000: kvseg
	addql	&1,dcn_cross_id		| identity region: one physical extent
	braw	Ldc_ret
Ldc_kv:
	addql	&1,dcn_cross_kv
	movel	%d0,%sp@-		| pa                        stack: pa ret va proc
	movel	%sp@(12),%sp@-		| proc
	movel	%sp@(12),%d1		| va
	oril	&0xfff,%d1
	addql	&1,%d1			| the first byte of the next virtual page
	movel	%d1,%sp@-
	jsr	vtop
	addql	&8,%sp			|                           stack: pa ret va proc
	moveal	%d0,%a1			| pa2
	movel	%sp@,%d0
	andil	&0xfffff000,%d0
	addil	&0x1000,%d0		| the frame that would make it contiguous
	moveq	&0,%d1
	cmpl	%a1,%d0
	beqs	Ldc_contig
	addql	&1,dcn_kv_scat
	moveq	&4,%d1
Ldc_contig:
	btst	&0,%a3@(3)		| B_READ
	beqs	Ldc_slot
	addql	&1,%d1
Ldc_slot:
	movel	dcn_ring_i,%d0
	andil	&15,%d0
	lsll	&5,%d0
	lea	dcn_ring,%a0
	addal	%d0,%a0
	addql	&1,dcn_ring_i
	movel	dcn_n,%a0@
	movel	%sp@(8),%a0@(4)		| va
	movel	%sp@,%a0@(8)		| pa
	movel	%a1,%a0@(12)		| pa2
	movel	%a3@(32),%a0@(16)	| len
	movel	%d2,%a0@(20)		| block
	movel	%a3@(92),%a0@(24)	| b_edev
	movel	%d1,%a0@(28)		| flags
	movel	%sp@+,%d0		| pa, the value startio stores in com.addr
Ldc_ret:
	moveal	%d0,%a0
	rts
	.balign 4

	.data
	.balign 4
	.globl	dcn_magic
dcn_magic:
	.long	0x44434e21		| "DCN!" -- static: proves the address
	.globl	dcn_on
dcn_on:
	.long	1
	.globl	dcn_n
dcn_n:
	.long	0
	.globl	dcn_cross_id
dcn_cross_id:
	.long	0
	.globl	dcn_cross_kv
dcn_cross_kv:
	.long	0
	.globl	dcn_kv_scat
dcn_kv_scat:
	.long	0
	.globl	dcn_ring_i
dcn_ring_i:
	.long	0
	.globl	dcn_ring
dcn_ring:
	.space	512
	.balign 4
