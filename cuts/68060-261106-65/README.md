# Cut 68060-261106-65

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `53e52e4` and amix
`46ef7d1`: the recipe of -64 (`../68060-261106-64`) with two fixes.  (`53e52e4` is `8629d20`, where the fixes were
made, with comments, tools and tests corrected; it builds the same bytes.)

- **A new ufs block in a hole is zeroed, a rewrite keeps alloc-only** (`src/ufs_bmap_hf.c`, `tools/ufs-holefix.sh`,
  `tools/bmaphf.py`; ISSUE-120): a whole-page write into a hole in the middle of a file got pagecreate from
  `as_iolock`, so `ufs_bmap` allocated the block alloc-only, neither read nor zeroed, and the block's pages the write
  did not cover read back the disk's old contents.  rwip's one call to `ufs_bmap` now goes to `ufs_bmap_hf`, which
  looks the block up first (`S_READ`, which allocates nothing and changes no inode field, under the inode lock rwip
  holds).  A hole turns alloc-only off, so `ufs_bmap` zero-fills the pages it allocates (the whole block, or up to the
  fragment the write ends in for the file's last block) in the cache before setting the block.  An allocated full
  block keeps alloc-only, so a rewrite runs as stock with no read; a last block held as a fragment is grown and read
  as stock.  `as_iolock` and every other caller of `ufs_bmap` are stock.  The routine is the 030 line's, the same
  code; `UFS_HOLE_FIX=0` builds the module without it, byte for byte -64's object.  The cost: `ufs_bmap_hf` sees only
  the write's end, so a write covering a whole new block (an 8 KiB append) is zero-filled first too, in memory.
- **A raw disk request past its slice end fails with ENXIO** (`src/patch_ddeof.py`; ISSUE-121): stock `ddread` and
  `ddwrite` (the SCSI disks and the Gayle IDE disk) clamped the residue to `size * 512 - offset`, negative past the
  end, and `uiophysio` made a ~4 GB count of it: EIO, or a sleep for ever on `Km_OsizeWanted`.  14 bytes in each
  function; `DD_EOF=0` builds them stock.  Stock's 32-bit end stays: s0 (the whole disk) ends at 0x7ffffe00 whatever
  the disk's size, and a slice of 4 GiB or more wraps.

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

The base (`b-new`) differs from -64's in the 22 bytes of the two end-of-slice tests (`.text 0xbd24-0xbd31`,
`0xbda2-0xbdaf`); `DD_EOF=0` builds -64's.  The kernel (`out/c/unix`) differs from -64's in those 22 and the build id.
The ufs object before the hole fix (`ufsmod/ufs-exp.k46` 1a147403, `ufs-exp-qz.k46` 006f1c9c) is -64's byte for byte,
although fsobj-patch's base (`b-new`) now carries the 22 bytes; `ufsmod/ufs-exp-hf.k46` is it
linked with `ufs_bmap_hf.o` and rwip's one `ufs_bmap` relocation retargeted (rwip's digest c2caf0e9 unchanged).  The
abi is -64's.  `cut.sh` adds the hole fix after the tail zeroing and records the eighth sum (`ufs-exp-hf.k46`).
`tools/bmaphf.py --selftest` and `tools/test-ddeof.py` pass.

## Proof (emulation, A4000 with the 68LC060 on the Z3660, unless said)

The kernel and module of this recipe's run (`SHA256SUMS-68060-261106-65`), installed as generation 2 by `kbootset`;
the test programs are `test-tools/sparsehole4k.c` and `test-tools/wcost.c`:

- **ISSUE-120.** 16 files with holes over a removed file of 0x5a, one 4 KiB page written into blocks 1-11 (direct) and
  15-25 (indirect), the cache pushed out, every block read back.  -64: with the block's second page written, 16 of 96
  direct pages wrong (8 of them the removed file's 0x5a, the rest other old contents) and 86 of 96 indirect (49);
  with the first, 96 of 96 direct.  -65: 0 of 96 in both cases, direct and indirect.  A page written past the end of
  file into a new block reads 0 of 16 wrong on both kernels (rwip zeroes that gap itself).
  `ufs_bmap_hf`'s counters (`modadmin -p ufs_hf_magic:4`) show both branches taken: holes 148 -> 12918 over the two
  passes (every new block, appends included), kept 8 -> 12107 after 8000 random 4 KiB rewrites.
- **No regression.** The file test of ISSUE-119 (append 4 KiB blocks tagged with number and generation, then random
  rewrites, appends and reads, every byte checked): 0 bad at 32 and 64 MiB (16384 blocks, 200000 operations) and at
  128 MiB (36864 blocks, 400000 operations, a 144 MB file).
- **Write cost** at 64 MiB, beside -64 (64 MB written by 4 KiB pages, copied by 8 KiB, 20000 random 4 KiB rewrites in a
  96 MB file; seconds by `time()`, two passes, two runs each on a loaded host): writes -64 12/12 and 11/12, -65 12/13
  and 11/11; rewrites -64 8/8 and 7/11, -65 9/8 and 7/8; the copy -64 26/29 and 27/29, -65 29/30 and 29/30, 2-3 s
  (7-11 %) slower in the first pass: the zero-fill of each new block.  The simpler rule this replaces (pagecreate only
  for a write covering its window) made the rewrites 19-30 s.
- **ISSUE-121.** On the 64 MiB boot slice c6d0s3: the last sector 1+0 and at the end 0+0 with rc 0, as -64; a read
  inside c6d0s4 (a slice that starts past 2 GiB on the disk; the offset within it is small) 8+0.  Past the end -65
  fails a 512 B read, a 1 MiB read and a 512 B write with ENXIO and nothing stays asleep; -64 failed them with EIO, -62
  with EIO and a 1 MiB read that never returned.  On the A4000D (-62, Z3660 68060) every past-the-end read tried never
  returned (asleep on `Km_OsizeWanted`, priority 25).
- **ISSUE-119 on hardware** (A4000D, -64, before this cut): a 144 MB file, all 400000 operations, 0 bad; -62 on the
  same disk first read wrong data at operation 62376 and the test stopped at its limit of 10 bad.
