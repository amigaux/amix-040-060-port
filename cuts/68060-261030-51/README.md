# Cut 68060-261030-51

The k46 module kernel, kabi k46.1.3 (abi 18c0a1c9), cut from this repository's `k46-module` at `3c6160d` with
the -61 recipe and the two fixes that are defaults there: the `kzero` fault catch (`KZERO=1`, ISSUE-107,
grimoire quirk 90) and the ufs tail zeroing (`UFS_TAILZERO=1`, ISSUE-108, quirk 91). The 68030 line's matching
cut is amix `kernel/k30/cuts/68030-261030-56`.

| File | What |
|---|---|
| `SHA256SUMS-68060-261030-51` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh`, `post-c.sh` | -61's chain and post steps, their directories taken from the run root |
| `families-c.json` | -61's family contract, its paths relative to the run root |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (carve.py's wrapper, `$build` this cut's) |

Inputs (`cut.sh` names each by an environment variable):

- this repository at `3c6160d` (`git archive`, the build tree; and a clone, which the kit and the gates read):
  `relink-040.sh` (the base kernel, kzero bound and checked), the Model-B sysroot, the module-kernel chain
  (carve, dd, sd4, f4arms, f6, audio, rth1, kinfo, dlm, fpe), and for the ufs module `tools/fsobj-patch.py`
  and `tools/ufs-tailzero.sh`; from its history, the five patchers `families-c.json` pins (rth1 hook
  `90f4cdb`, ttcompat `c2d7cad`, pgrsv `7905bd1`, isp060 `148f785`, tcp hiwat `c25d93d`, their helper
  `6e8f973`);
- amix at `e45b061` (amix-dlm's history, kept by the move-in): the module core and `make kit`;
- amix-paula at `62fdcab` (the audio driver's three patchers, as in -61);
- gcc-cross-amix at the commit amix's `toolchain/gcc-cross-amix.pin` names (gcc 2.7.2.3, `8949028`);
- amigaux/amix-system: `kernels/2.1c/unix`, the stock kernel the relinks check against;
- NetBSD 10.1's `syssrc.tgz` (the FPSP; `tools/netbsd-pin.sh` checks it);
- amix-kerntools at `bd091b4`: its `tools/` and `contracts/` (the sddevsize and W-D7 injectors,
  `emit-family-chains.py`, `k0-gates.py`). **Not public yet**: these move to amix `kernel/k30/tools`, and
  `cut.sh` then takes them from there;
- optional: the frozen candidate-3 kernel (`5aa7d732`) that emit and k0-gates compare against. It is
  not a build input: without it the sums are the same and k0-gates refuses only its control row.

The build is stamped `68060-261030-51`: `SOURCE_DATE_EPOCH=1793318400` (2026-10-30), the build sequence seeded
`261030 50`, and the block lookup pinned to this cut's (50-99), so the stamp does not depend on who rebuilds.

`unix` is the module kernel (installed as `/stand/k46/unix`), `kabi` its sidecar, `abi-k46.1.3.txt` the ABI
text the kabi's `abi=` hashes. `ufs.mod` is the core-tier ufs module bound to this build (module kabi k46.1.2),
built from `ufs-exp-qz.k46`: the ufs object `fsobj-patch.py` makes (`ufs-exp.k46`, the same as -61's) with
`src/ufs_vptrunz.c` bound in by `ufs-tailzero.sh`. `b-new` is the base kernel the chain starts from.

Against -61 (`516faa6b`): the kernel adds the `kzero` unit (.text +136 bytes, .data +92) and keeps kabi
k46.1.3 and its abi; the ufs module adds the tail zeroing. Against the ISSUE-107/108 test build -50 the kernel
and the module differ only in the build id. -61's M-REG1 measurement is not part of this recipe.

`cut.sh` reproduces all seven sums outside any git checkout, with and without the control kernel (with it,
k0-gates is ALL GREEN). Verified in emulation (an A4000 with a 68060): the quirk-91 probes clean in every warm,
remount and cold run, the nine quirk-90 cases, and a smoke, with -61 as the control showing both defects.
Hardware acceptance on the A4000T follows.
