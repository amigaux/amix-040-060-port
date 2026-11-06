# Cut 68060-261106-65

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `8629d20` and amix
`46ef7d1`: the recipe of -64 (`../68060-261106-64`) with two fixes.

- **A new ufs block is zeroed, a rewrite keeps alloc-only** (`src/ufs_bmap_hf.c`, `tools/ufs-holefix.sh`,
  `tools/bmaphf.py`; ISSUE-120): a whole-page write into a hole in the middle of a file, or into a new block past
  its end, got pagecreate from `as_iolock`, so `ufs_bmap` allocated the block alloc-only, neither read nor zeroed,
  and the block's pages the write did not cover read back the disk's old contents.  rwip's one call to `ufs_bmap`
  now goes to `ufs_bmap_hf`, which looks the block up first (`S_READ`, allocating nothing, under the inode lock rwip
  holds): a hole turns alloc-only off, so `ufs_bmap` zero-fills the new block in the cache before setting it; an
  allocated block keeps it, so a rewrite runs as stock, with no read.  `as_iolock` and every other caller of
  `ufs_bmap` are stock.  The routine is the 030 line's, the same code; `UFS_HOLE_FIX=0` builds the module without
  it, byte for byte -64's object.
- **A raw SCSI disk request past its slice end fails with ENXIO** (`src/patch_ddeof.py`; ISSUE-121): stock `ddread`
  and `ddwrite` clamped the residue to `size * 512 - offset`, negative past the end, and `kmem_alloc` slept for ever
  on the ~4 GB count `uiophysio` made of it.  14 bytes in each function; `DD_EOF=0` builds them stock.

| File | What |
|---|---|
| `SHA256SUMS-68060-261106-65` | the eight files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs in its header; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -64's, the core at `46ef7d1` |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261106-65`: `SOURCE_DATE_EPOCH=1793923200` (2026-11-06), the build sequence seeded
`261106 64`, the block lookup pinned to 50-99.

## What differs from -64

The base (`b-new`) is -64's.  The kernel (`out/c/unix`) differs from -64's in 23 bytes: the 22 of the two
end-of-slice tests (`.text 0xbd24-0xbd31`, `0xbda2-0xbdaf`) and the build id.  The ufs object before the hole fix
(`ufsmod/ufs-exp.k46` 1a147403, `ufs-exp-qz.k46` 006f1c9c) is -64's; `ufsmod/ufs-exp-hf.k46` is it linked with
`ufs_bmap_hf.o` and rwip's one `ufs_bmap` relocation retargeted (rwip's digest c2caf0e9 unchanged).  The abi is -64's.
`cut.sh` adds the hole fix after the tail zeroing and records the eighth sum (`ufs-exp-hf.k46`).
`tools/bmaphf.py --selftest` and `tools/test-ddeof.py` pass.

## Proof (emulation, A4000 with the 68LC060 on the Z3660, unless said)

The kernel and module of this recipe's run (`SHA256SUMS-68060-261106-65`), installed as generation 2 by `kbootset`:

- **ISSUE-120.** 16 files with holes over a removed file of 0x5a, one 4 KiB page written into blocks 1-11 (direct) and
  15-25 (indirect), the cache pushed out, every block read back.  -64: with the block's second page written, 16 of 96
  direct and 86 of 96 indirect pages read the removed file's data; with the first, 96 of 96 direct.  -65: 0 of 96 in
  both cases, direct and indirect, and 0 of 16 for a page written past the end of file.
- **No regression.** The file test of ISSUE-119 (append 4 KiB blocks tagged with number and generation, then random
  rewrites, appends and reads, every byte checked): 0 bad at 32 and 64 MiB (16384 blocks, 200000 operations) and at
  128 MiB (36864 blocks, 400000 operations, a 144 MB file).
- **Write cost** at 64 MiB, beside -64 (64 MB written by 4 KiB pages, copied by 8 KiB, 20000 random 4 KiB rewrites in a
  96 MB file; seconds, two passes): -64 rewrites 8/8 and 7/11, -65 9/8 and 7/8; writes and copies equal.  The simpler
  rule this replaces (pagecreate only for a write covering its window) made the rewrites 19-30 s.
- **ISSUE-121.** On the 64 MiB boot slice c6d0s3: the last sector 1+0, at the end 0+0 with rc 0, a read inside c6d0s4
  (which starts past 2 GiB) 8+0, all as -64.  Past the end -65 fails a 512 B read, a 1 MiB read and a 512 B write with
  ENXIO and nothing stays asleep; -64 failed them with EIO, -62 with EIO and a 1 MiB read that never returned.  On the
  A4000D (-62, Z3660 68060) every past-the-end read slept for ever on `Km_OsizeWanted`.
- **ISSUE-119 on hardware** (A4000D, -64, before this cut): a 144 MB file at 400000 operations, 0 bad; -62 on the same
  disk first read wrong data at operation 62376.
