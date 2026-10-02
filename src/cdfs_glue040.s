| cdfs_glue040.s -- what relink-040-cdfs.sh links beside amix-cdfs's libcdfskern.o (2026-10-02,
| PO-02).
|
| THE ROW.  The kernel's vfssw[] is a 12-row static table, and nfstype cannot grow in a binary
| relink, so cdfs takes a row that exists: RFS's, row 4 (D44).  src/patch_cdfs_vfssw.py retargets
| that row's two relocations -- its name to cdfs_vsw_name below, its init from rf_init to
| cdfsinit -- and asserts first that nothing in the kernel reaches row 4 except by walking the
| table or by a filesystem-type number taken from a mounted vfs (the PO-02 proof, recorded in
| KNOWN-ISSUES DRIVER-LINE-3).  cdfsinit finds its row by the name "cdfs" (amix-cdfs,
| platform/amix-kernel/cdfs_vfsops.c), so the name is the interface.
|
| THE RFS GUARD.  With rf_init no longer called, RFS's tables (sndd, rcvd, gdp) are never
| allocated.  Every RFS path is then gated on rf_state, which stays RF_DOWN because RF_START
| refuses a NULL sndd with ENOSYS -- the stock kernel's own answer for RFS configured off -- except
| two that walk gdp without that gate: rf_setidmap and rf_freeidmap, reached by rfsys(RF_SETIDMAP)
| (root only; idload).  With gdp NULL that walk would read and write kernel addresses 0..0xde0.
| cdfs_rfsys sits in sysent[78] in rfsys's place and gives every RFS subcommand the RF_START
| answer while sndd is NULL; once sndd exists (no kernel of this pass allocates it) it is rfsys.
|
| cdfs_glue_magic "CDF4" first, then cdfs_rfsys_denied: rfsys calls answered ENOSYS here.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/cdfs_glue040.s -o build/cdfs_glue040.o
| Linked LAST by relink-040-cdfs.sh: the .balign 4 closes both section totals.

	.text

	.globl	cdfs_rfsys
cdfs_rfsys:				| sysent[78]: sp@(4) uap, sp@(8) rvp
	tstl	sndd
	beqs	Lcdfs_norfs
	jmp	rfsys			| RFS's tables exist: the stock system call
Lcdfs_norfs:
	addql	&1,cdfs_rfsys_denied
	moveq	&89,%d0			| ENOSYS, as rfsys_start returns for a NULL sndd
	rts
	.balign 4

	.data
	.balign 4
	.globl	cdfs_glue_magic
cdfs_glue_magic:
	.long	0x43444634		| "CDF4" -- static: proves the address
	.globl	cdfs_rfsys_denied
cdfs_rfsys_denied:
	.long	0			| rfsys calls answered ENOSYS: RFS is not configured
	.globl	cdfs_vsw_name
cdfs_vsw_name:
	.asciz	"cdfs"			| vfssw[4].vsw_name: cdfsinit looks its row up by this
	.balign 4
