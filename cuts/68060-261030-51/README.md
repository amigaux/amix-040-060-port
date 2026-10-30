# Cut 68060-261030-51

The k46 module kernel, kabi k46.1.3 (abi 18c0a1c9), cut from this repository's `k46-module` at `3c6160d` with
the -61 recipe and the two fixes that are defaults there: the `kzero` fault catch (`KZERO=1`, ISSUE-107,
grimoire quirk 90) and the ufs tail zeroing (`UFS_TAILZERO=1`, ISSUE-108, quirk 91). The 68030 line's matching
cut is amix `kernel/k30/cuts/68030-261030-56`.

| File | What |
|---|---|
| `SHA256SUMS-68060-261030-51` | the seven files of record, paths relative to the cut's output directory |

Inputs:

- this repository at `3c6160d`: `relink-040.sh` (the base kernel, kzero bound and checked), the Model-B
  sysroot, the module-kernel chain (carve, dd, sd4, f4arms, f6, audio, rth1, kinfo, dlm, fpe), and for the ufs
  module `tools/fsobj-patch.py` and `tools/ufs-tailzero.sh`;
- amix `kernel/dlm` at `e45b061` (`make kit`, the k46 kit the modules are checked against);
- amix-paula at `62fdcab` (the audio driver's three patchers, as in -61);
- gcc-cross-amix at the commit amix's `toolchain/gcc-cross-amix.pin` names (gcc 2.7.2.3, `8949028`);
- the stock 2.1c `stand/unix` the relinks check against.

The build is stamped `68060-261030-51`: `SOURCE_DATE_EPOCH=1793318400` (2026-10-30) and the build sequence
seeded so that the one stamp is -51.

`unix` is the module kernel (installed as `/stand/k46/unix`), `kabi` its sidecar, `abi-k46.1.3.txt` the ABI
text the kabi's `abi=` hashes. `ufs.mod` is the core-tier ufs module bound to this build (module kabi k46.1.2),
built from `ufs-exp-qz.k46`: the ufs object `fsobj-patch.py` makes (`ufs-exp.k46`, the same as -61's) with
`src/ufs_vptrunz.c` bound in by `ufs-tailzero.sh`. `b-new` is the base kernel the chain starts from.

Against -61 (`516faa6b`): the kernel adds the `kzero` unit (.text +136 bytes, .data +92) and keeps kabi
k46.1.3 and its abi; the ufs module adds the tail zeroing. Against the ISSUE-107/108 test build -50 the kernel
and the module differ only in the build id.

Two independent builds gave the same seven sums. Verified in emulation (an A4000 with a 68060): the quirk-91
probes clean in every warm, remount and cold run, the nine quirk-90 cases, and a smoke, with -61 as the
control showing both defects. Hardware acceptance on the A4000T follows. `cut.sh` joins this record once
its inputs are all public.
