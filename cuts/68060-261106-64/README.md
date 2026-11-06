# Cut 68060-261106-64

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `fa24df6` and amix
`46ef7d1`: the recipe of -63 (below) with the ufs module's write fix.

- **ufs rwip passes base + mapon to segmap_pagecreate** (`tools/fsobj-patch.py`, the module-only site `rwip`; ISSUE-119):
  Amix's compiled `ufs_rwip` passed the 8 KiB segmap window's base, where SVR4's `ufs_vnops.c` passes base + mapon
  (the write's offset in the window).  A whole-page write that starts past the window's start (mapon != 0) and that
  `as_iolock` lets skip the read (a page-aligned write of whole 4 KiB pages, or one reaching end of file) then created
  the window's first pages instead of the written ones, without reading them: valid, clean, holding the frame's old
  contents, while the disk held the right data.  The fix is 4 bytes of the module object (`.text 0x8a4c`,
  `2f2eff94` -> `48703800`, `pea %a0@(0,%d3:l)`), its surrounding instructions and relocations checked;
  `UFS_RWIP_FIX=0` builds the module without it, byte for byte -63's object.
- **Still open (ISSUE-120):** a whole-page write into a hole in the middle of a file leaves the rest of the newly
  allocated block reading the disk's old contents.  It is `ufs_bmap`'s, not rwip's; this cut does not change it.

| File | What |
|---|---|
| `SHA256SUMS-68060-261106-64` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -63's, the core at `46ef7d1` |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261106-64`: `SOURCE_DATE_EPOCH=1793923200` (2026-11-06), the build sequence seeded
`261106 63`, the block lookup pinned to 50-99.

## -63

`68060-261105-63` is -62's recipe with this repository at `0508945` (the 32-record kept stores and the swap guard's
resize path on top of -62), built the same way but not kept as a directory here; -64 replaces it.  Its seven sums:

    aa38885ebd774d626bbde835c424bd43c3c6030c9d8e7583c3a35196d0d1e642  out/c/unix
    e78ba3cf4e4c28762c59d248d100960d6e0d734ca5c73404fa37c60437930e50  out/c/kabi
    83173887356f2c52e9d3f5c19c6ebb694f4d8463b8238781086887ce8e814a17  out/c/ufs.mod
    18c0a1c98b2c9284fb10a6b6386403ed5e13193e3ec7aa4f113ff2a174285378  out/c/abi-k46.1.4.txt
    6636b27edf42b1a6b52856668f789edbfd567040ee45b8831bba35ec7fc910f9  ufsmod/ufs-exp.k46
    f49bf55e3048b2a3ff30cc4dc3b9d02ab31e979fd389d346925c2f60da4c0b8e  ufsmod/ufs-exp-qz.k46
    dcc0c587e5c274166bb33f5f3bdaaade3c1ed7d87a7b5743011d2b78e5e8874c  port/build/b-new

"-63" below means that kernel (unix aa38885e).  A test build of the same commit with the 8 MiB arena turned off
(`ARENA8M=0`, unix f0c9fcba) carries the same build id; it is not -63.

## What differs from -63

The base (`b-new` dcc0c587) is -63's, and the kernel differs from -63's only in its build id (2 bytes).  The ufs
object (`ufsmod/ufs-exp.k46` 1a147403) differs from -63's in the 4 bytes above; `ufs.mod` (c4594dd8, `ufsmod/Master`
`$build 68060-261106-64`) differs from -63's in those 4 bytes and its build id (2 bytes), and from the module tested
below only in its build id.  The abi is -63's; the kabi differs only in its build and the kernel's sha256 lines.
`cut.sh` reproduces all seven sums in `amix-toolchain:dist`.  `tools/test-fsobj-patch.sh` passes.

## Proof (emulation, A4000 with the 68LC060 on the Z3660)

A file test (one process: append 4 KiB blocks tagged with their number and generation, then random 4 KiB rewrites,
appends and reads, every byte checked) at 64 MiB, 16384 blocks and 200000 operations:
- -63's ufs module: the first run after each boot first reads wrong data at operation 30174 (a second run in the same
  boot at 32720), always an even 4 KiB block (the window's first page); in the one run whose disk was read back after
  sync, the disk held the right block and generation at all 10 bad blocks; the cached pages of the file held their
  frames' old contents, one of them another file's data;
- the same kernel with this ufs module: 0 bad in three runs.  A paused check of every cached page of the file found
  none holding another block; a page of zeros at the append frontier (the page being written when the emulator
  paused, gone at the next check) showed in 1 of 23 checks.
-64 itself (kernel 3dd5b94c): 0 bad at 32 MiB (64 MB file), 64 MiB and 128 MiB (144 MB file, 400000 operations); the
page check found the same append-frontier page in 3 of its 23 checks and nothing else.
