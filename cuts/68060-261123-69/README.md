# Cut 68060-261123-69

The k46 module kernel, kabi k46.1.7 (abi 18c0a1c9), for the next line: cut from this repository's `next` at `0d796ad`
and amix `812c763e`, on the recipe of -68 (`../68060-261120-68`).

- **Disk commands of 4 KiB** (`src/patch_pageio4k.py`, DRIVER-LINE-5): raw disk transfers and `buf_breakup`'s later
  pieces go out in 4096 bytes, not 2048; half the SCSI commands per raw transfer.
- **The stock soft data and vmem limits** (ISSUE-124): 16 MiB, hard limits unlimited, as in the stock kernel; -56 to
  -68 raised them to unlimited.  `ulimit -d unlimited` and `ulimit -v unlimited` raise them.
- **Module core 0057-0059** (amix `kernel/dlm`): `sd_limits`, `sd_lim` and `sdqueuex` (C4-7, disk commands with
  segment lists), kabi k46.1.7; the undefined-symbol and module-call messages name where they come from.

| File | What |
|---|---|
| `SHA256SUMS-68060-261123-69` | the eight files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs in its header; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -68's, with kabi k46.1.7; `post-c.sh` also checks the shipped image below |
| `kern46m-new-in.txt` | the package's "New in -69" sentence on the limits; `post-c.sh` checks it against the built table |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261123-69`: `SOURCE_DATE_EPOCH=1795392000` (2026-11-23), the build sequence seeded
`261123 68`, the block lookup pinned to 50-99.  Two runs of `cut.sh` give the same eight sums.

`post-c.sh` checks on the shipped image, besides -68's checks: `sd_limits` defined and in the kit's `ddi.list` as
minor 7; `patch_rlimits.py --expect stock` (soft data and vmem 0x1000000, hard 0x7fffffff); kernel/k30's
`rlimits-check.py` at the amix pin, which reads the image's table and fails unless `kern46m-new-in.txt` says the same
("soft data and vmem limits 16 MiB"); `patch_pageio4k.py --check` (the three sites at 4096).

## What differs from -68

Measured per symbol (relocations masked) against -68's kernel of record: `amiga_dma_pageio` (two bytes) and
`buf_breakup` (one), the 4 KiB constants; `rlimits` (two words); the module core's functions from 0057-0059
(`sd_limits`, `sd_lim`, `sdqueuex`, `sdreg_of` and `dlm_modcall` new; `dlm_undef`, `lf_fail`, `dlm_load1`,
`dlm_unload`, `dlm_halt`, `dlm_ddi_sweep`, `sd_register`, `dlm_defer_run` changed, with the core's message strings
and `dlm_fsstub`, `dlm_ksym`); the kabi string (`kinfo_kabi`, `dlm_static`) and the ident bytes (`buildid`,
`dlm_ident`); nothing else.  The base is b-new 7c7813d1, `next`'s base since `0aa2bcf`.  The abi fingerprint and the
three ufs objects are -68's; `ufs.mod` differs from -68's in its build id only (2 bytes).

## Proof (emulation, A4000 with the 68LC060 on the Z3660)

On the 1.1.1 k46 X disk (kernel -68 after its first boot, the 1.1.1 module set, z3660rtg), the cut's kernel, sidecar,
ufs module and a kernel record laid in place of -68's and composed by the disk's own kbootset (check, build, commit,
generation 4), then four boots of generation 4:

- **The kernel.**  `uname` names 68060-261123-69 on every boot of generation 4; the emulator's fault counts are the
  same on each of them as on the disk's own boot of -68 (Gary 13, illegal 0, traps 0).
- **The limits.**  A login shell has `ulimit -d` 16384 and `ulimit -v` 16384 (KB), the rest as before.  This disk's
  base package has no `xstart`, so a session's own limits were not seen here.
- **The rest, as on -68.**  vfork and fork keep a child's arguments (5 of 5) and the parent finds nothing at the exec
  stack hole; a 200-round shell exec loop, nested shells and `ls -R /usr/lib`; every module answers as under -68 (ufs,
  z3660scsi, z3660eth, zz9kbus and random loaded; cdfs, monsw, paula and z3660rtg load on use; a4091, a4kt710,
  gayle and buddha refused, no such controller; xsurf and zz9ksvc no such device); `/dev/zz9000` reads; the kmem
  check runs.
- **A TCP loopback stall, as before.**  kernel-tests' scheck pair with 2048-byte socket buffers on both ends stalls
  (two runs of ten repetitions, each stopped after 900 s); a STREAMS pipe and AF_UNIX pass 10 of 10.  Nothing in this
  cut touches that path.

## Proof (hardware)

On the A4000D (68060, A4092 + Zulu scratch): three boots of -69 by kbootset; a login shell 16384/16384 KB, an xstart
session on the Z3660 65536/131072 KB; raw and ufs write/verify 64 MiB pass at -68+PAGEIO4K's rates.
