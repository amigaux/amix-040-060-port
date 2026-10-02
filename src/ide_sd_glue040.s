| ide_sd_glue040.s -- register the Gayle IDE driver (amix-gayle-ide, ide.c) with sd on the driver
| line, below the controllers the base already registers (2026-10-02, P-15 P2).
|
| HOW sd FINDS A CONTROLLER.  sd.c's init() walks its controller table and, for each row, asks
| autocon(id, n, &addr, &aux) for the n-th board with that autoconfig id; every answer goes to
| insert(queue, n, addr, name), which keeps SDCARDS (2) slots sorted by addr, ascending.  So the
| card number of a board is its rank by address, and a third board is dropped.
|
| WHY A GLUE.  The A4000's IDE port is not an autoconfig board, so autocon never answers for it.
| On the 030 line the patched sd.c calls the driver's own probe when the autocon table has no
| entry (ide.c's header, "Registration").  Here sd.c is a binary, so relink-040-ide.sh gives the
| table one more row, with an id no board carries (IDE_SD_ID below), and retargets init()'s one
| `jsr autocon` (.rela.text 0xd78e) onto ide_sd_autocon: that id is answered by idepresent(),
| every other id goes to autocon unchanged.  idepresent() runs its chipset gate before it touches
| a task-file address, so this is safe on a machine without the port.
|
| THE ORDER RULE (owner decision pending; this is the "Z3660 stays card 0, IDE next" shape, and
| it is switchable).  The address this glue hands insert() is a SORT KEY, not a bus address:
|   ide_sd_key = 0xfffffff0 (default)  IDE sorts after every real board, so the boards the base
|                                      registers keep their card numbers and IDE takes the next
|                                      free slot.  With two other boards present, IDE is dropped.
|   ide_sd_key = 0 (IDE_ORDER=address) the task-file base idepresent() reports (0xdd2020), so
|                                      IDE ranks by address like any board -- ahead of the Z3660
|                                      and of any Zorro III board, i.e. card 0.
| The key is only a rank: ide.c never asks sd for its card's address (no sdcardbase() import),
| so nothing reads it back as one.
|
| ide_sd_magic "IDE#" first, ide_sd_key, then ide_sd_found: 1 once idepresent() said yes.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/ide_sd_glue040.s -o build/ide_sd_glue040.o
| Linked LAST by relink-040-ide.sh: the .balign 4 closes both section totals.

	.text

	.globl	ide_sd_autocon
ide_sd_autocon:				| entry: sp@(4) id, sp@(8) n, sp@(12) &addr, sp@(16) &aux
	cmpl	&0x1de0a400,%sp@(4)	| IDE_SD_ID -- the row relink-040-ide.sh adds; no board has it
	beqs	Lide_row
	jmp	autocon			| every real id: the stock answer, unchanged
Lide_row:
	tstl	%sp@(8)
	bnes	Lide_none		| there is one IDE port: only n = 0 answers
	subql	&4,%sp			| char *base, filled in by idepresent
	movel	%sp,%sp@-
	jsr	idepresent
	addql	&4,%sp
	movel	%sp@+,%d1		| the task-file base
	tstl	%d0
	beqs	Lide_none
	movel	&1,ide_sd_found
	movel	ide_sd_key,%d0
	bnes	Lide_key
	movel	%d1,%d0			| key 0: rank by the real base
Lide_key:
	moveal	%sp@(12),%a0
	movel	%d0,%a0@		| *addr: the sort key insert() ranks by
	moveq	&1,%d0
	rts
Lide_none:
	moveq	&0,%d0
	rts
	.balign 4

	.data
	.balign 4
	.globl	ide_sd_magic
ide_sd_magic:
	.long	0x49444523		| "IDE#" -- static: proves the address
	.globl	ide_sd_key
ide_sd_key:
	.long	0xfffffff0		| the rank IDE gets in sd; 0 = its real base (IDE_ORDER=address)
	.globl	ide_sd_found
ide_sd_found:
	.long	0			| 1 once idepresent() answered for the IDE row
	.balign 4
