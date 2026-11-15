# Cut 68060-261115-67

The k46 module kernel, kabi k46.1.6 (abi 18c0a1c9), for the 1.1 line: cut from this repository's `release-1.1` at
`59e1b77` and amix `09b89ffb`, on the recipe of -66 (`../68060-261106-66`).

- **fb_register, DDI k46.1.6** (amix kernel/dlm, core patch 0056 and `core/plat/k46/line.c`): a module asks, from its
  `_load`, for the framebuffer cache class (non-cacheable, not serialised) on a page-aligned window inside one Zorro III
  device board.  It is a wrapper over this port's `hat_cm_fb_add` and its two `hat_cm_fb` {lo, hi} slots
  (`src/hat040.s`), unchanged.  A slot stays with the module that took it for the rest of the boot; the refusals are
  EINVAL (outside `_load`, unaligned, not inside one device board), EBUSY (overlaps a window another holder has) and
  ENOSPC (both slots held), each with one console line.
- **sync() skips every filesystem while rootdir is 0** (`src/syncguard.s`, ISSUE-123): a generation that cannot mount
  its root panics once instead of twice.
- The rest of the core's change against -66: 0054 (modadmin, user side only), 0055 (a zorro match key with product
  00), the major registry with c 56 xsurf and c 68 va2000.

| File | What |
|---|---|
| `SHA256SUMS-68060-261115-67` | the eight files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs in its header; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -66's, with the core at `09b89ffb`, `DLM_KABI` and `KINFO_KABI` k46.1.6, the reference `abi-k46.1.6.txt`, and a check that the shipped image defines `fb_register` and the core's list names it as minor 6 |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261115-67`: `SOURCE_DATE_EPOCH=1794700800` (2026-11-15), the build sequence seeded
`261115 66`, the block lookup pinned to 50-99.

## What differs from -66

Measured per symbol (relocations masked) against a control built by this recipe with the port at `388b93b`, which
builds -66's port bytes (b-new 555b5e5f, -66's):

- **control against -66, the core alone:** `fb_register`, `fb_same`, `fb_holder`, `plat_board_window` and
  `dlm_curname` new; `plat_line_zwin`, `plat_match`, `root_defer`, `dlm_ld_free`, `okmatch` changed; the ksym table
  grows by one entry (6512 -> 6544 bytes), the major registry by two rows; `kinfo_kabi` and the ident say k46.1.6;
  `.text` +792 bytes, `.data` +380, `.bss` +48 (`fbheld`).  The base is -66's.
- **-67 against the control, the port alone:** `sync` (32 -> 42 bytes), `Lsgnoroot` new, `syncg_skip_root` new;
  nothing else but the ident record.  The base is b-new 456b22fd.

The abi fingerprint is -66's (18c0a1c9): k46.1.6 adds a name to the DDI list, not a layout.  The ufs objects
(`ufs-exp.k46` 1a147403, `ufs-exp-qz.k46` 006f1c9c, `ufs-exp-hf.k46` 1efb27a0) are -66's; `ufs.mod` differs from
-66's in its build id only (3 bytes) and still says kabi k46.1.2.  kbootset-min stays 1.1.0.261103-37.  A second run of
`cut.sh` gives all eight sums equal to the record.

## Proof (emulation, A4000 with the 68LC060 on the Z3660)

On the released 1.1 k46 disk (the 1.1 image after its first boot: kernel -66, the 1.1 module set, z3660rtg with its
emulation-only fixed base), the cut's kernel, sidecar, ufs module and kernel record laid in place of -66's and composed
by the disk's own kbootset:

- **The 1.1 modules.**  `kbootset check` passes all 13 installed modules (kabi tags 1.2, 1.3 and 1.4); build and commit
  make generation 3 with kernel -67.  Its first boot is the trial and the boot script marks it good and the default.
  Every module behaves as under -66 on the same disk: ufs, z3660scsi, z3660eth, zz9kbus and random loaded; cdfs, monsw,
  paula and z3660rtg load on first use and `/dev/zz9000` reads; a4091, a4kt710 and gayle (no such controller here) and
  zz9ksvc (ENXIO) are refused the same way on both kernels.
- **fb_register.**  A test module (`fbt`, kabi k46.1.6, from its `_load`) on the Z3660's Zorro III board 144B:1 at
  0x40000000 (128 MiB), in generation 4: the console prints `dlm: fbt: framebuffer 0x40010000+0x100000 non-cacheable,
  not serialised` and the same for 0x40200000+0x100000; the refusals print one line each: two EINVAL (an unaligned
  window, one past the board), EBUSY (inside window 0), ENOSPC (a third window).  fbt's own line: `0 22 22 16 0 28 0`
  (want `0 22 22 16 0 28 0`).  `hat_cm_fb`, read through `/dev/kmem` at `cmf_magic`+20: `00040010 00040110 00040200
  00040300`, all zero in generation 3.  After `modadmin -U fbt` and a load again the answers are the same and the table
  is unchanged.
- **The claim is checked.**  On the same disk under -66, `kbootset build` refuses fbt: `gate 2 (kabi): module fbt is
  built for kabi k46.1.6, the kernel is k46.1.4`.
