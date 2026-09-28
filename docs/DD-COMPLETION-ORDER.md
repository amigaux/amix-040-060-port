# dd.c completion order: issue the next command before `iodone()` (2026-09-27)

**Status: EMU run (DL-13, 2026-09-28): not refuted, not proven. HW: not run.** The acceptance is
a boot, and this document says why that matters more than usual here.

DL-13 in Amiberry, with the WD vehicle and the emulated Z3660:
- Row 1, a board-less boot to multiuser, boots clean with this fix.
- The double issue was not provoked, not even on the control kernel without the fix: the
  mailbox trace shows zero duplicate commands. So the run cannot show that the fix removes it.
- Both kernels stalled the same way. The stall belongs to the emulator's Z3660 path, not to this
  fix: on metal the same load completes (T-8).

Build: `relink-040-dd.sh` (post-pass, before `relink-040-fpe.sh`), `src/dd_order040.s` (two
shims), `src/patch_dd_order.py` (two relocation retargets). Addresses are those of every base of
this line; the site sits in the stock prefix of `.text`, which no relink moves.

## 1. The defect

dd.c's interrupt completion is the file-static `ihandle` (`.text 0xbfb6`–`0xc0c6`). On a
successful completion it advances the unit's queue head, calls `iodone(bp)`, and only then calls
`startio(FIRST, dp)` for the next command. `iodone` runs the buffer's `b_iodone` callback; for a
chunked transfer that callback submits the next chunk through `ddstrategy`, synchronously, while
the completion is still inside `iodone`. `ddstrategy` starts the unit only when the queue head is
empty — and the head was advanced before `iodone` — so the resubmit issues a command itself, and
`ihandle`'s own trailing call then issues the head again: the same `&dp->com` twice. The fix
(carried at source by amix-z3660scsi on the 68030 line) is the order: issue next, then `iodone`.

## 2. The site

Before (stock, `objdump -dr` of `build/unix-040-driver-line`):

```
c08e: 2f0c            movel %a4,%sp@-             error path: push dp
c090: 4878 0002       pea 2                        ...and 2 (retry)
c094: 6000 0020       braw c0b6                    ...into the shared tail call
c098: 4a28 0006       tstb %a0@(6)
c09c: 6700 0006       beqw c0a4
c0a0: 7404            moveq #4,%d2
c0a2: 8593            orl %d2,%a3@
c0a4: 296b 000c 0004  movel %a3@(12),%a4@(4)       dp->bhead = bp->next
c0aa: 2f0b            movel %a3,%sp@-              push bp
c0ac: 4eb9 0000 0000  jsr iodone                   R_68K_32 iodone  @c0ae
c0b2: 2f0c            movel %a4,%sp@-              push dp   (bp is never popped; unlk does it)
c0b4: 42a7            clrl %sp@-                   push FIRST (0)
c0b6: 4eb9 0000 0000  jsr startio                  R_68K_32 startio @c0b8
c0bc: 4cee 1c04 fff0  moveml %fp@(-16),%d2/%a2-%a4
c0c2: 2040            moveal %d0,%a0               ihandle returns startio's d0
c0c4: 4e5e            unlk %fp
c0c6: 4e75            rts
```

After: the same bytes; only two relocations differ (`readelf -rW`, and a whole-image relocation
diff shows no other change outside the appended shims):

```
                          stock                      after
.rela.text @0xc0ae        iodone                  -> dd_issue_first
.rela.text @0xc0b8        startio                 -> dd_startio_tail
```

By symbol index, as `src/patch_dd_order.py` wrote them in the pass output
(`build/unix-040-driver-line-dd`): `iodone` (sym 13041, 0x3c980) → `dd_issue_first` (sym 15818,
0xf66f0); `startio` (sym 16047, 0xc0c8) → `dd_startio_tail` (sym 15107, 0xf670e). Indices are
renumbered by every later `ld -r`; in the end of the smoke chain (`…-dd-fpe`) the same two records
read `003f7701 dd_issue_first` and `003c8f01 dd_startio_tail`. The names and values are what
persist.

The shims (`src/dd_order040.s`, 44 bytes, imports exactly `iodone` and `startio`):

```
dd_issue_first:                      entry: sp@ = return (c0b2), sp@(4) = bp
    movel %a4,%sp@-                  dp
    clrl  %sp@-                      FIRST
    jsr   startio
    addql &8,%sp
    movel %d0,%sp@-                  keep startio's result on this frame
    movel %sp@(8),%sp@-              bp (source read before the push)
    jsr   iodone
    addql &4,%sp
    movel %sp@+,%d0                  startio's result back
    rts                              to c0b2, stack as after the stock jsr iodone
dd_startio_tail:                     entry: sp@(4) = first argument
    tstl  %sp@(4)
    bnes  1f                         not FIRST: exactly the stock call
    rts                              FIRST: already issued; d0 is that result
1:  jmp   startio
```

## 3. Why the second shim may rely on the argument

- **Every path into `c0a4`–`c0bc`** (whole-`.text` branch scan and every relocation resolved):
  `c004`, `c010`, `c018`, `c09c` → `c0a4`; `c0a0` falls into `c0a4`; `c094` → `c0b6`; `c024` →
  `c0bc`. Nothing outside `ihandle` branches in; the only relocation into `ihandle` is its entry,
  stored as the completion callback at `0xc186` inside `startio`.
- So `c0b6` is reached in exactly two ways: falling through from `jsr iodone` with first argument
  **0**, or from the error path with **2**.
- `startio` stores its first argument as the unit's state word, which `ihandle` dispatches on:
  0 normal, 1 request-sense (set by `getsense`), 2 retry. The tail passes only 0 or 2.
- **Return path.** `c0b2`/`c0b4` are two pushes and the shim's `tstl`/`bnes`/`rts` touch only the
  condition codes, and the `moveml` mask at `c0bc` excludes `d0`, so `moveal %d0,%a0` at `c0c2`
  sees what `dd_issue_first` returned: `startio(FIRST, dp)`'s result. On an empty queue `startio`
  returns without setting `d0`, in stock and here alike.
- **Registers.** The shims write `d0` and the stack only. `a4` is `dp` on every path to `c0ac`
  (written once, at `bfe0`/`bfe2`) and is callee-saved; the stock code already relied on it
  surviving `iodone`.
- **Nesting.** The saved result lives on each invocation's own frame, so a completion delivered
  inside `iodone` keeps its own value.

## 4. The 2026-07-31 precedent — what it does and does not tell us

`docs/Z3660-KERNEL-FEASIBILITY-260731.md` §5 records the first attempt: the island
`dd_startio_first` (`src/z3660_glue040.s`, still opt-in behind `Z3660_DD_ORDER=1` in
`patch_z3660.py`) retargeted **only** `@0xc0ae`. That kernel panicked before the banner
(illegal instruction at `byteread+0x2`, `startio+0xcc <- sdqueue`, double panic). With only the
first relocation moved, the stock `jsr startio` at `c0b6` still ran after `iodone`, so with two or
more buffers queued the next command was issued twice. **That is a hypothesis for the panic, not
an established cause**: the record itself leaves the cause open, and a double issue needs two
queued buffers before the banner. The other candidate — that issuing before `iodone` is itself
unsafe on the stock A3091/SDMAC host — is shared by this unit. So the argument above settles the
machine-level correctness of the shims, and only a boot settles the rest: DL-13 (emulator, the
WD vehicle and the emulated Z3660) is the acceptance, and a board-less boot to multiuser is its
first row.

The two edits cannot coexist and fail closed in either order: `relink-040-dd.sh` refuses a base
whose `@0xc0ae` names `dd_startio_first`, `patch_dd_order.py` aborts with a dedicated message, and
`patch_z3660.py` refuses a kernel whose `@0xc0ae` no longer names `iodone`.

## 5. What this does not fix

- **The SCSI tape object has the same pattern and is untouched.** Its completion (`ihandle` at
  `0xb1ba` → `machine` → `dispose`) advances the head, calls `iodone`, then writes the unit state
  and loops to start the next request; tape read/write also resubmit through `uiophysio` →
  `breakup`. Same double-issue class; out of scope here (the disk path is what every image uses).
  The third local `ihandle` (`0xdedc`, the `gs` object) only wakes a sleeper and has no queue.
- **Recursion depth** of a host that completes synchronously inside `sdqueue` equals the queue
  depth in either order; the fix removes the double issue, not the depth. amix-z3660scsi bounds
  the depth with its own completion FIFO (no `timeout()` deferral: that was fatal for a
  stack-resident request).
- With such a host the issue-first order runs `iodone` for the later buffers before the earlier
  one. Independent buffers do not care; nothing here validates a consumer that would.

## 6. Build and gates

```
AMIX_ALLOW_UNKNOWN_STOCK=1 sh relink-040-dd.sh build/unix-040 build/unix-040-dd
```

(`AMIX_ALLOW_UNKNOWN_STOCK=1` only on a machine whose stock kernel is the one in
`docs/STOCK-KERNEL-HASH.md`.) The pass refuses a base that carries the FPE, lacks FPSP, has weak
symbols, has more than one `startio`, or whose two sites are not stock; it asserts the shims'
exact import and export sets, no name collision, `scan060` CLEAN, the instruction bytes around
both calls and the error path, zero addends, and after the link a single global `startio`, no
unresolved symbol, the two retargets in place, text/data contiguity and 4-alignment,
`patch_b2_flip --check`, `check_relink_relocs` (`TOTAL complaints: 0`). The z3660, zz9000 and FPE
passes run over its output with the retargets intact; the hgfault040 binding and
`tools/status-facts.sh` (`bindings failing: 0`) still hold on the result.
