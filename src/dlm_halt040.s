| dlm_halt040.s -- the module core's halt pass on the halt and reboot paths (amix-dlm core
| patch 0030, S4-07; 2026-10-26).
|
| uadmin's A_SHUTDOWN and A_REBOOT end in mdboot, which calls haltsys (halt) or rtnfirm (reboot).
| Each module's _halt must run before either, newest first, so a board that can write memory is
| stopped before the machine halts or the ROM takes over.  relink-040-dlm.sh retargets mdboot's two
| calls onto these shims (src/patch_dlm_halt.py); each calls dlm_halt() and then tail-jumps to the
| stock routine with the stack exactly as mdboot built it.  dlm_halt takes no argument, and its
| second call returns at once, so either order of the two is safe.
|
| Not in haltsys040.s and not in rtnfirm: panic (xpanic, xcmn_err) and the keyboard reset
| (kbintr) reach those too, and must not run module code.
|
| Linked only when the core defines dlm_halt, so a kernel cut at an earlier core is unchanged.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/dlm_halt040.s -o build/dlm_halt040.o

	.text
	.globl	dlm_halt_haltsys
dlm_halt_haltsys:			| mdboot, fcn 0: sp@(4) is haltsys's argument
	jsr	dlm_halt
	jmp	haltsys
	.globl	dlm_halt_rtnfirm
dlm_halt_rtnfirm:			| mdboot, a reboot
	jsr	dlm_halt
	jmp	rtnfirm
