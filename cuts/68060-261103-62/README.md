# Cut 68060-261103-62

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `84b0623` and amix
`46ef7d1`: the recipe of [`68060-261103-61`](../68060-261103-61/README.md) with the kernel-memory readers' names back
in the kernel (ISSUE-115).

- **The core tier keeps five COMMONs** (amix kernel/dlm `abi/k46/core.list`): `inode`, `ifreelist` (s5's),
  `ufs_inode`, `inodeNINODE`, `ifreeh` (ufs's).  The carve used to drop every COMMON only the ufs and s5 ranges use;
  `src/carve_fs040.py` now keeps a core-tier one (gate B and `--check` leave the core tier out), so the kernel's
  namelist has them, and the module core binds the ufs module's COMMONs to the kernel's copies (no module rebuild).
- **An empty s5 inode table** (the module core, `plat_line_zwin`): k46 has no s5, so `inode` points at a read-only
  run of 30 kernel pages all mapped to one zeroed page -- `ninode` x 200 bytes of free entries, which is what `sadc`
  reads -- instead of 0.
- **kbootset-min `1.1.0.261103-37`** (the core's floor file): kbootset -37 writes `crash_sync`'s word and the loaded
  modules' globals into `/stand/unix`.

| File | What |
|---|---|
| `SHA256SUMS-68060-261103-62` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -61's, the core at `46ef7d1` |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261103-62`: `SOURCE_DATE_EPOCH=1793664000` (2026-11-03), the build sequence seeded
`261103 61`, the block lookup pinned to 50-99.

## What differs from -61

The base (`b-new` 7c570d91) is -61's: the carve and the core come after it.  The kernel exports 213 names (208 + the
five); the abi is -61's (`mkabi --check` no moved line); ufs.mod differs by its build id.  `cut.sh` reproduces all
seven sums in `amix-toolchain:dist` with the control (k0-gates ALL GREEN), `ksymgate` 12 of 12 on the shipped form,
every core-tier name defined with its listed kind.

## Proof (emulation, this cut's image bc8e779f, kbootset -37 and modadmin -12 on the box)

On an A4000 with a plain 68040 (IDE root) and on the A4000 with the 68LC060 on the Z3660 (installed by `kbootset`
-37, generation 9):
- `adb -k` reads `inode` = an address in the kvseg band (0x4008a000 / 0x40165000) whose words read 0, `ninode` 600,
  `ufs_inode` and `inodeNINODE` set by the ufs module's init;
- `sar -v 1 1` prints `0/600` inodes with no error, `sar -u 1 1` and `timex -s sleep 1` print their tables, `sadc`
  rc 0 (on -61 all four end `sadc cannot copy inode table`);
- `wbkeep` passes (ISSUE-114 unchanged).
`crash` gets past the namelist (on -61: `could not read namelist timestamp`) and then stops at `<addr> is an
invalid address`: it validates kernel addresses by walking the stock 68030 tables through `kas`, which the k46
kernel does not keep for region 1 -- the same family as `adb -k`'s kvseg translation.  Recorded in ISSUE-115.
