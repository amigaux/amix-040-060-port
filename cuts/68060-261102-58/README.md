# Cut 68060-261102-58

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `7d7e6a7` and amix
`46c269c`: the recipe of [`68060-261101-57`](../68060-261101-57/README.md) with two changes.

- **The user-trap diagnostics are off the trap path.** `src/patch_trapdiag_off.py` runs on the f6 output: the
  relocation of `utraps`' call at `.text 0x11f0` names `u_trap` again (it named `kvd_utraps`, the vector-dispatch
  census, which tail-jumped to `srg_utraps`, the ISSUE-106 user-trap ring, which tail-jumped to `u_trap`), and the
  census's switch `kvd_on` is 0. Both objects stay linked and no address moves. Together they cost about 43
  non-cacheable accesses on every system call and user fault; on the 68LC060 at 80 MHz the census alone measured
  8.6 us of getpid's 70 (kvd_on 1 / 0: 70.3 / 61.4 us).
- **amix `46c269c`**: `kernel/dlm` is `ac168e5`'s plus core patch 0052, the interrupt-chain early-out: each
  module interrupt chain keeps its count of attached handlers, and the level-2 walk and the level-6 wrapper run
  the chain only when it is not 0. The rest of what changed in amix between them (kbootset, its packages, the
  contracts, tests, `mkkit.sh`'s path guards, the k30 sidecar tool) does not reach this cut's outputs; the kit's
  abi is unchanged.

| File | What |
|---|---|
| `SHA256SUMS-68060-261102-58` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh` | -57's with `patch_trapdiag_off.py` after f6; `TRAPDIAG=1` leaves the diagnostics on (the control) |
| `post-c.sh` | -57's at amix `46c269c` |
| `families-c.json` | -57's family contract, unchanged |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

Inputs (`cut.sh` names each by an environment variable; all of them public): as -57's, with this repository at
`7d7e6a7` and amix at `46c269c`. The build is stamped `68060-261102-58`: `SOURCE_DATE_EPOCH=1793577600`
(2026-11-02), the build sequence seeded `261102 57`, the block lookup pinned to 50-99.

## What differs from -57

- **This cut against its control** (`TRAPDIAG=1`, the same recipe with the diagnostics left on): 3 bytes of
  `out/c/unix` (`kvd_on`'s low byte, and the two bytes of the 0x11f0 relocation's symbol index), and the sidecar's
  `sha256=` line.
- **The control against -57**, symbol by symbol (every `.text`/`.data` symbol paired by name, its bytes compared with
  relocation fields masked, its relocations compared with section-relative addends resolved to symbol + offset):
  the core's `dlm_int2_walk`, `aciabintr`, `intr_attach`, `intr_detach`, `dlm_intr_sweep`, `dlm_intr_count`, the new
  `dlm_intr_attached` and the two `.bss` counts `int2_n`/`int6_n`; four 32-bit pc-relative displacements across the
  core's 140 added bytes, each re-aimed at the same target; the build id (`buildid`, the ident `dlm_ident` with the
  ident, arena and ksym addresses, and `dlm_ksym`'s address and size of `intr_attach`). Nothing else: 7 849 `.text`,
  2 232 `.data` and 322 `.bss` symbols, the ones after the core 140 bytes further on.
- The sidecar: `build=`, `size=`, `sha256=`, and the `ident=`, `arena=` and `ksym=` addresses. The abi, both ufs
  objects and the base `b-new` are -57's; the ufs module differs in its build id only. The kit is -57's, so the
  module packages built for -56 and -57 (pin `33ebadc`, kabi k46.1.4) load unchanged.

`cut.sh` reproduces all seven sums in `amix-toolchain:dist` (gcc-cross-amix `33ebadc`, gcc14's binutils 2.43.1 as
`G14` = `/opt/amix/gcc14-cross-amix/build`), with the control (k0-gates ALL GREEN) and without it; `ksymgate` 12 of
12 on the shipped form, `mkabi --check` no moved line. The same image reproduces -57's seven sums from -57's
`cut.sh`.

In emulation (Amiberry, row N241a, 64 MB, -57 beside it on the same rig and script): kbootset check, build and
commit rc 0, mark-good; tdemand's output equal to -57's but for times and random bytes; the zero page and nullread
SIGSEGV, the 16 pm probes, exectest PASS; both rows PASS. fpebench getpid 8.6 and 7.3 us against -57's 9.9 and 9.9;
fmovex unchanged within the emulator's spread. Amiberry does not model the Z3660's non-cacheable access cost, so the
size of the gain is for the 68LC060 to measure.
