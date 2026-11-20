# Cut 68060-261120-68

The k46 module kernel, kabi k46.1.6 (abi 18c0a1c9), for the 1.1 line: cut from this repository's `release-1.1` at
`43f80fc` and amix `09b89ffb`, on the recipe of -67 (`../68060-261115-67`).

- **hat_exec unloads the old address space's stack image** (`src/hat_exec040.s`, ISSUE-125): exec builds the new
  stack in the current address space and moves it; under vfork that space is the parent's and survives, and the
  port's no-op `hat_exec` left its translations live, so the next vfork child's exec wrote its arguments into an
  earlier child's stack (CDE's dtsession clients).  `hat_exec` now calls `hat_unload` on that range and moves nothing.

| File | What |
|---|---|
| `SHA256SUMS-68060-261120-68` | the eight files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs in its header; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -67's |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261120-68`: `SOURCE_DATE_EPOCH=1795132800` (2026-11-20), the build sequence seeded
`261120 67`, the block lookup pinned to 50-99.

## What differs from -67

Measured per symbol (relocations masked) against -67 rebuilt by its own recipe (all eight sums equal -67's record):
`hat_exec` (4 -> 64 bytes, a call to `hat_unload`), its local label `Lhx_done`, and the ident bytes in `buildid` and
`dlm_ident`; nothing else.  The base is b-new fde937f7.  The abi fingerprint, the three ufs objects and kbootset-min
are -67's; `ufs.mod` differs from -67's in its build id only (3 bytes).  The soft data and vmem limits are -67's
(unlimited, as on the whole 1.1 line).  Three runs of `cut.sh` give the same eight sums.

## Proof (emulation, A4000 with the 68LC060 on the Z3660)

On the released 1.1 k46 disk (kernel -66 after its first boot, the 1.1 module set, z3660rtg), the cut's kernel,
sidecar, ufs module and kernel record laid in place of -66's and composed by the disk's own kbootset (check, build,
commit, generation 3), then one boot of generation 3:

- **vfork.**  A program that vforks child A (keeps its argv, checks it 4 s later) and then child B with other
  arguments: A's argv intact after every vfork (3 of 3) and fork (2 of 2).  On -67 the same disk shows 3 of 3 changed
  (A's argv reads B's strings, argv[argc] 0x42424242, A and B die with user bus errors).  A probe in the parent finds
  nothing readable at the exec stack hole (0x8005f000) after a vfork child's exec; on -67 it reads the child's
  argument string there.
- **The rest.**  0 bus errors; a 200-round shell exec loop, nested shells and `ls -R /usr/lib` as on -67; every module
  as under -67 on the same disk (ufs, z3660scsi, z3660eth, zz9kbus and random loaded; cdfs, monsw, paula and z3660rtg
  load on use; a4091, a4kt710 and gayle refused, no such controller); `/dev/zz9000` reads; the kmem check runs.
