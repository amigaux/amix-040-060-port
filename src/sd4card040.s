| sd4card040.s -- dd's and ct's tables for four cards, and their card decodes (2026-10-26).
|
| amix-dlm C4-1 section 2.1: in the minor, the card's low bit is bit 3 and its high bit bit 7,
|   sdcard(dev) = (dev >> 3 & 1) | (dev >> 6 & 2)
| so cards 0-1 keep their minors.  The stock dd.o and ct.o were built with SDCARDS 2: per-card
| tables of two rows, and sdcard() inlined at every use as the six bytes
|   lsrl #3,Dn ; moveq #1,Dm ; andl Dm,Dn          (asrl in two of ct's)
| relink-040-sd4card.sh retargets the tables' relocations to the four-row copies below and
| replaces each six-byte decode with a six-byte `bsr.l` to the helper for its register pair
| (src/patch_sd4card.py).  A helper leaves what the stock bytes left: Dn the card, Dm 1, and the
| condition codes of `andl` (N and Z of the card, V and C clear).  bsr.l is PC-relative: the
| patched image's .text is one section, so it needs no relocation.
|
| One of ct's decodes is not of a dev but of a table index: ct.c sets a command's card from
| `dp - cttab[0]` (8 * card + unit), which for four rows is (index >> 3) & 3 (sd4_idx_d1d2).
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/sd4card040.s -o build/sd4card040.o
| Linked LAST by relink-040-sd4card.sh: it carries the .balign 4 that closes both sections.

	.text

| dev in Dn -> card in Dn, 1 in Dm, CCR as `andl`
	.globl	sd4_dev_d0d1
sd4_dev_d0d1:				| dd ddopen, startio; ct strategy
	movel	%d0,%d1
	lsrl	&3,%d0
	andil	&1,%d0			| card low bit: minor bit 3
	lsrl	&6,%d1
	andil	&2,%d1			| card high bit: minor bit 7
	orl	%d1,%d0
	moveq	&1,%d1
	tstl	%d0
	rts
	.globl	sd4_dev_d0d2
sd4_dev_d0d2:				| dd ddioctl; ct init
	movel	%d0,%d2
	lsrl	&3,%d0
	andil	&1,%d0			| card low bit: minor bit 3
	lsrl	&6,%d2
	andil	&2,%d2			| card high bit: minor bit 7
	orl	%d2,%d0
	moveq	&1,%d2
	tstl	%d0
	rts
	.globl	sd4_dev_d1d2
sd4_dev_d1d2:				| dd ddprint
	movel	%d1,%d2
	lsrl	&3,%d1
	andil	&1,%d1			| card low bit: minor bit 3
	lsrl	&6,%d2
	andil	&2,%d2			| card high bit: minor bit 7
	orl	%d2,%d1
	moveq	&1,%d2
	tstl	%d1
	rts
	.globl	sd4_dev_d1d3
sd4_dev_d1d3:				| dd ddstrategy
	movel	%d1,%d3
	lsrl	&3,%d1
	andil	&1,%d1			| card low bit: minor bit 3
	lsrl	&6,%d3
	andil	&2,%d3			| card high bit: minor bit 7
	orl	%d3,%d1
	moveq	&1,%d3
	tstl	%d1
	rts
	.globl	sd4_dev_d1d4
sd4_dev_d1d4:				| ct ctclose
	movel	%d1,%d4
	lsrl	&3,%d1
	andil	&1,%d1			| card low bit: minor bit 3
	lsrl	&6,%d4
	andil	&2,%d4			| card high bit: minor bit 7
	orl	%d4,%d1
	moveq	&1,%d4
	tstl	%d1
	rts
	.globl	sd4_dev_d0d5
sd4_dev_d0d5:				| ct ctopen (two)
	movel	%d0,%d5
	lsrl	&3,%d0
	andil	&1,%d0			| card low bit: minor bit 3
	lsrl	&6,%d5
	andil	&2,%d5			| card high bit: minor bit 7
	orl	%d5,%d0
	moveq	&1,%d5
	tstl	%d0
	rts

| ct: the card of a cttab index (8 * card + unit) in %d1 -> card in %d1, 1 in %d2
	.globl	sd4_idx_d1d2
sd4_idx_d1d2:
	asrl	&3,%d1
	andil	&3,%d1
	moveq	&1,%d2
	tstl	%d1
	rts
	.balign 4			| pad .text to a 4-byte multiple

	.data
	.balign 4
| struct dd is 68 bytes, struct ct 72 (the stock tables are 2 x 8 x 68 = 1088 and 2 x 8 x 72 = 1152)
	.globl	sd4_ddtab
sd4_ddtab:
	.space	4 * 8 * 68
	.size	sd4_ddtab, 4 * 8 * 68
	.globl	sd4_cttab
sd4_cttab:
	.space	4 * 8 * 72
	.size	sd4_cttab, 4 * 8 * 72
	.balign 4			| pad .data likewise
