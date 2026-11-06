# Cut 68060-261106-64

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `fa24df6` and amix
`46ef7d1`: the recipe of `68060-261105-63` (this repository at `0508945`) with the ufs module's write fix.

- **ufs rwip passes base + mapon to segmap_pagecreate** (`tools/fsobj-patch.py`, the module-only site `rwip`):
  Amix's compiled `ufs_rwip` passed the segmap window's base, where SVR4's `ufs_vnops.c` passes base + mapon.
  Writing whole pages into an 8 KiB UFS block anywhere but at its start then created the block's first pages
  without reading them: valid, clean, holding the frame's old contents, while the disk held the right data.
  The fix is 4 bytes of the module object (`.text 0x8a4c`, `2f2eff94` -> `48703800`, `pea %a0@(0,%d3:l)`), its
  surrounding instructions and relocations checked; `UFS_RWIP_FIX=0` builds the module without it, byte for byte
  -63's object.

| File | What |
|---|---|
| `SHA256SUMS-68060-261106-64` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -63's, the core at `46ef7d1` |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261106-64`: `SOURCE_DATE_EPOCH=1793923200` (2026-11-06), the build sequence seeded
`261106 63`, the block lookup pinned to 50-99.

## What differs from -63

The base (`b-new` dcc0c587) is -63's, and the kernel differs from -63's only in its build id (2 bytes).  The ufs
object (`ufsmod/ufs-exp.k46` 1a147403) differs from -63's in the 4 bytes above; `ufs.mod` (c4594dd8, `ufsmod/Master` `$build 68060-261106-64`) differs from
the module tested below only in its build id (2 bytes).  The abi is -63's;
the kabi differs only in its build and the kernel's sha256 lines.  `cut.sh` reproduces all seven sums in
`amix-toolchain:dist`.  `tools/test-fsobj-patch.sh` passes (14 module-only sites, 17 bytes; the fix's refusals).

## Proof (emulation, A4000 with the 68LC060 on the Z3660)

A file test (one process: append 4 KiB blocks tagged with their number and generation, then random 4 KiB rewrites,
appends and reads, every byte checked) at 64 MiB, 16384 blocks and 200000 operations:
- -63's ufs module: every run reads wrong data from operation 30174 on, always the first 4 KiB of an 8 KiB block;
  the disk holds the right data at every one of them, and the pages in the cache hold their frames' old contents;
- the same kernel with this ufs module: 0 bad in three runs, and no cached page of the file holding another block
  at 23 checks during a run.
