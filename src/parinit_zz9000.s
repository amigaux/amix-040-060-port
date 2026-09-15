| parinit_zz9000.s -- call zz9000init() from the kernel's parallel-port init hook, so the
| Z3660 RTG driver's board probe runs at boot (2026-09-15).
|
| Same reason as src/parinit_va2000.s and the z3660 glue: io_init[] = { parinit, 0 } and
| init_tbl[] both end in a NULL word that carries no relocation, so there is no slot to
| retarget to zz9000init and the hook has to be a `parinit` WRAPPER.
|
| What is different here is that the base this wraps ALREADY carries a parinit wrapper: in
| every kernel of the z3660 lineage (f7vs, r13) `parinit` is src/z3660_glue040.s's override,
| which stores the zen0 streamtab into cdevsw[51].d_str and then jumps to the stock body,
| exposed there as `parinit_orig`.  So this wrapper must chain to THAT wrapper, never to
| `parinit_orig` -- reaching past it would skip the streamtab store and zen0 would open as
| nodev.  relink-040-zz9000.sh reads the current strong `parinit` address from nm of the base
| and exposes it as parinit_zz9000_orig (the FPE pass's `_fpe_orig` naming, for the same
| reason: the address moves with every build and is never taken from a note).
|
| The chain at run time: io_init[0] -> this -> z3660 wrapper -> stock parinit.  zz9000init
| takes no arguments and its return value is unused by the io_init[] walker.  What it does
| at that moment is the driver's: on the Z3660 row it reads the board's version registers
| at the fixed base 0x10000000 with plain supervisor loads, gated only on an AGA chipset.
| So it prints one line and returns on a non-AGA machine or with the board answering; on an
| AGA machine with nothing at that address the read is a supervisor bus error at io_init
| time.  This wrapper cannot change that, and the kernel it is linked into is for the one
| machine where the board is there.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/parinit_zz9000.s -o build/parinit_zz9000.o
| Linked LAST: a compiled object is not guaranteed to end its sections on a 4-byte boundary
| (the driver's .data is 2 mod 4), and the loader places .bss at data_end unaligned, so the
| .balign 4 here closes the link (BUILDING.md, the .balign law).

	.text
	.globl	parinit
parinit:
	jsr	zz9000init		| Z3660 RTG board probe at the fixed base
	jmp	parinit_zz9000_orig	| the z3660 wrapper, then the stock parallel-port init
	.balign 4			| pad .text to a 4-byte multiple

	.data
	.balign 4			| pad .data likewise (the driver's .data is 2 mod 4)
