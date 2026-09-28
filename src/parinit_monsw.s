| parinit_monsw.s -- call monswinit() from the kernel's parallel-port init hook (P-8, 2026-09-28).
|
| io_init[] and init_tbl[] end in a NULL word with no relocation, so a new init entry is a
| `parinit` WRAPPER, as src/parinit_zz9000.s explains.  This one chains to whatever strong
| parinit the base carries -- on the z3660 lineage that is src/z3660_glue040.s's wrapper --
| which relink-040-monsw.sh reads from nm of the base and exposes as parinit_monsw_orig.
|
| monswinit takes no arguments and touches no hardware: it only settles a patched value and
| reports it.  Nothing in monsw.c depends on it having run first (all of its state is
| initialised data), so its place in the chain does not matter to the card drivers.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/parinit_monsw.s -o build/parinit_monsw.o
| Linked LAST: it carries the .balign 4 that closes both sections (BUILDING.md, the .balign law).

	.text
	.globl	parinit
parinit:
	jsr	monswinit		| settle and report a patched switch value
	jmp	parinit_monsw_orig	| the base's parinit, wrapper or stock
	.balign 4			| pad .text to a 4-byte multiple

	.data
	.balign 4			| pad .data likewise
