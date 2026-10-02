# The 060 "arms" without a Z3660 — design note for P-15 K2 (2026-10-02)

**Status: desk analysis, no code, no boot.** The question comes from amix-kerntools (KT-42,
`docs/k0-families.md`). `relink-040-f4arms.sh` and `relink-040-f6.sh` refuse a base without
`z3660queue`, so a 040/060 kernel for another accelerator (K2 / KD0x0-U: A3640, CyberStorm Mk III,
Warp Engine, Apollo, with an A4091/A4092 or the A3000 WD) gets only the arm-less shape
`dd → a4091 (D42) → fpe`. Kerntools recorded that shape as carrying "the KT-19 risk".

## 1. What each arm is

There are four arms across two passes. Three are instruments: they record and count, and by
their own headers they change no behaviour. One changes behaviour, and only inside the Z3660
SCSI driver.

| Arm | Object | Hooks | What it does | Behaviour | Imports (besides its own) | Z3660-specific? |
|---|---|---|---|---|---|---|
| f4arms `--ufault` | `src/ufault_dbg.s` | chained in front of the ISSUE-106 latch at the fatal user-fault NOTICE | records the first fatal user fault (registers, FSLW, u_ar0, rootdir); keeps a LAST block and user-stack watermarks | none ("changes no behaviour and dereferences no user address") | `unt_latch`, `u`, `rootdir` | no |
| f4arms `--cache N` | `src/z3660_cache_arm.s` + `patch_z3660_cache.py` | gives amix-z3660scsi's COMMON `z3660_cache` a `.data` home, stamped to N | turns on the **piscsi driver's own** data-cache push/invalidate around its transfers | **yes, in the z3660 driver only** | none (absorbs the driver's COMMON) | **yes, entirely** |
| f6 `--kvd` | `src/kvecdisp040.s` | in front of the user-trap latch at the `utraps → srg_utraps` edge | reads M68Kvec and the VBR; twin counters | none: tail-jumps with the stack byte-identical | `kvp_n kvp_on M68Kvec nullvect srg_ut_n srg_utraps` | no |
| f6 `--swa` | `src/swapadd_dbg.s` | swapconf's one `jsr swapadd` | records the four operands, swapinfo on either side, and the return, then calls swapadd | none | `swapadd_real swapinfo` | no |

(f4arms `--dbg` / `swapconf_dbg.s` and f6 `--mcs` are the older instruments that the KD chains do
not use.)

All base symbols the three instruments import exist in a plain `relink-040.sh` base. Checked on
`build/unix-040-dl-po18`: 7 of 7 present (`unt_latch`, the `kvp_*`/`srg_*` latch, `M68Kvec`,
`swapinfo`). None of them imports a z3660 symbol. **The `z3660queue` refusal in both scripts is a
pass-order guard ("belongs after relink-040-z3660.sh"), not a dependency.** The one real dependency
is that `--cache` needs the driver's `z3660_cache` COMMON, and that f6 re-checks that the cache
arm is baked in.

## 2. What the cache knob does, and what plays its part elsewhere

It was measured on 68LC060 silicon in attempt 4 (`docs/060-F4-M2-ATT4-RESULTS-260825.md`):
- `z3660_cache = 60` (arm B): `swapconf` configures swap, and the boot reaches userland.
- `z3660_cache = 0` (the control): `PANIC: swapconf lookupname /dev/dsk/ced0s2 failed - error 20`.

The cause is the piscsi data path: the card's ARM side writes disk data into RAM, the 060's data
cache still holds stale lines, so a directory read returns stale bytes. The knob makes the driver
push before each transfer and invalidate after a read. **That is coherence for one host adapter,
not a 060 property.** On another machine each host adapter must provide its own:

| Host adapter | Its coherence on this line | Where |
|---|---|---|
| A4091 / A4092 | D42: `dma_prepare` / `dma_complete` around every transfer, plus the A4-18 bounce for misaligned FROM_DEVICE edges. Always on with `-DA4091_D42`; no knob | `relink-040-a4091.sh`, amix-a4091 |
| A3000 WD (SDMAC) | Antti's B2 pilot (`src/dma_cache040.s`): push before arm, range-invalidate after stop. In the base, always on | `relink-040.sh`; metal-proven by Antti on A3000 + A3640 / Mercury |
| A2091 | none, so not a supported root (D47) | — |
| Z3660 piscsi | the `z3660_cache` knob | `relink-040-f4arms.sh --cache 60` |

**So nothing replaces the knob on a non-Z3660 kernel, and nothing needs to.** The D42 build of the
a4091 driver, or the WD's B2, is that kernel's equivalent. What has to be true is that the D42
object is the one linked (`-DA4091_D42`, never the stub arm) on any 060 family.

## 3. KT-19, read again

Kerntools' KT-19b record lists two causes. Both bind on a Z3660 machine only:
1. **The MG8 hang was W-D7.** It hung "right after the zz9000/monsw boot lines, before the z3660
   unit table". The stock `autocon` registers a phantom A3000 SCSI at `$DD0000`, which on the
   A4000T is the onboard 53C710; "the probe alone clears the disk-probe stall — W-D7 WAS the
   hang". This binds on every AGA machine: an A4000 with an accelerator spins in a3091's
   `cipwait` on Gayle (N8 before KT-12A-W). That is the W-D7 rule ("any kernel that goes to metal
   carries W-D7"), not an arm.
2. **The next stop, swapconf's `lookupname`, is the Z3660 cache arm (§2).** KT-19b attributes it to
   "without the f6 `--swa` arm". `--swa` only records around `swapadd`, which runs after the
   lookup, so it cannot prevent that panic. The p10 kernels lacked both passes, and the cache arm is
   what attempt 4 shows closes the stop.

**So the arm-less shape is not, in itself, the KT-19 risk.** `dd → a4091 (D42) → fpe → W-D7` has
the two things KT-19 needed: the probe, and its host adapter's own coherence. That is the KD060-A
and KD040-A recipe plus W-D7 and D42. It already passes on the emulator in N6 (CyberStorm Mk III
060), N7 (Warp 040), N8 (A3640-shape 040, with W-D7) and E9 (A3000 040).

**What remains open, and the arms would not have closed it:** the emulator has no data cache
(`cpu_data_cache=false`, no copyback model), so those passes say nothing about coherence. The D42
verdict on silicon is MD-1 (KT-42, the A4092 in the A4000D, a Z3660 machine) and MD-4 (040 silicon,
none on our benches). A non-Z3660 060 on metal has never run any of these kernels.

## 4. Can the generic arms run without a Z3660?

Yes, with small guard changes and no object changes:
- **f4arms:** require `z3660queue` only when `--cache` is given. `--ufault` takes any finished base.
  (`--dbg` keeps the requirement: it can skip swap, so it is not an instrument, and the KD chains
  do not use it.)
- **f6:** require the cache arm (`z3660_cache` in `.data`) only when the base has `z3660queue`.
  Without the driver, there is no knob to require. The header's warning ("a different kernel: no
  cache arm") is true only on a Z3660.
- **The chain order** is unchanged: `dd → [a3q] → a4091 (D42) → f4arms --ufault → f6 --kvd --swa →
  [ide] → [cdfs] → fpe → W-D7`. The instruments touch none of the relocations the driver passes
  edit.

What they buy is diagnosability, not correctness. On a first metal boot of a CyberStorm or Warp
kernel, a userland wall or a swapconf stop leaves a record (`uft_*`, `kvd_*`, `swa_*`) instead of a
bare hang. That is how the Z3660 bring-up was debugged. Their cost is 143 symbols and a few hundred
bytes, with no runtime path changed.

## 5. Test plan (emulator first; no bench in this note)

Build two K2 shapes on the current base: **A** = arm-less (`dd → a4091 D42 → fpe → W-D7`) and
**B** = A plus `f4arms --ufault` and `f6 --kvd --swa`.

| Row | Machine | Expectation for A and B | What it can show |
|---|---|---|---|
| N6 | A4000, CyberStorm Mk III 060, A4091 root | login, `/` on the A4091, clean halt; B's `uft_n` = 0, `swa_*` latched once | no regression from the instruments; that the 060 path works without Z3660 code |
| N7 | A4000, Warp Engine 040, A4091 root | as N6 (KD040-A) | the same on 040 |
| N8 | A4000, A3640-shape 040, A4091 root | as N6, with W-D7 required (the pre-probe kernel spins in a3091's `cipwait`) | W-D7 is the binding fix, not the arms |
| E9 | A3000, 040, A4091 root behind the WD vehicle | as N6 | A3000 shape with the WD present |
| N14 (proposed: not yet in `matrix.tsv`) | A3000, 060 (Mercury-shape RAM at 0x08000000), **root on the onboard WD** | login and clean halt on Antti's shape | the WD/B2 path with a 060 K2 kernel; pairs with P1's a3q pass |

Predictions, written before any run:
- A and B behave identically on every row, because the instruments change no behaviour. Any
  difference is a defect in a guard change.
- No row can say anything about cache coherence (no data cache in the emulator).
- A row that fails on A fails on B, and B's latches should say where.

## 6. Effort

| Item | Size |
|---|---|
| Guard changes in f4arms/f6 (conditional `z3660queue` and cache-arm checks), with negative controls | S (half a day) |
| Build A and B on the current base; four rows plus N14 (needs a kerntools row definition and a vehicle) | S–M (rig time) |
| Metal coherence verdict for a non-Z3660 060 + A4091 | not ours to schedule: MD-1 is on a Z3660 machine; a CyberStorm/Warp/Apollo board is not on any bench |

## 7. Recommendation

1. **Do not block K2 on the arms.** Ship the K2 060/040 shape as `dd → (a3q) → a4091 (-DA4091_D42)
   → (ide) → (cdfs) → fpe → W-D7`. W-D7 is the binding fix, and D42 (or the WD's B2) is the
   binding coherence. Nothing in the Z3660 arms applies to a machine without a Z3660.
2. **Do make the instruments available**, as a separate small change (S). Relax the two guards so
   `--ufault`, `--kvd` and `--swa` run on any base, and put them in the EXPERIMENTAL K2 kernels:
   the first metal boot on someone's CyberStorm should leave a record, not a black screen.
3. **Correct the KT-19b wording** in kerntools' record. The swapconf `lookupname` panic is the
   missing Z3660 cache arm, not the missing `--swa`.
4. **Label K2 EXPERIMENTAL** until a non-Z3660 060 + A4091/A4092 has run on metal. The emulator
   rows prove the code paths, not the coherence.
