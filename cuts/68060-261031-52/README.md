# Cut 68060-261031-52

The k46 module kernel, kabi k46.1.3 (abi 18c0a1c9), cut from this repository's `k46-module` at `fff9660`: the
recipe of [`68060-261030-51`](../68060-261030-51/README.md) with the STREAMS freeq guard (`FREEQ_GUARD=1`,
ISSUE-109, grimoire quirk 92), a default there beside `KZERO=1` (ISSUE-107) and `UFS_TAILZERO=1` (ISSUE-108).
The 68030 line's matching cut is amix `kernel/k30/cuts/68030-261031-63`.

| File | What |
|---|---|
| `SHA256SUMS-68060-261031-52` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh`, `post-c.sh` | -61's chain and post steps, their directories taken from the run root (as -51) |
| `families-c.json` | -61's family contract, its paths relative to the run root |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (carve.py's wrapper, `$build` this cut's) |

Inputs (`cut.sh` names each by an environment variable; all of them public):

- this repository at `fff9660` (`git archive`, the build tree; and a clone, which the kit and the gates read):
  `relink-040.sh` (the base kernel, kzero and the freeq guard bound and checked), the Model-B sysroot, the
  module-kernel chain, and for the ufs module `tools/fsobj-patch.py` and `tools/ufs-tailzero.sh`; from its
  history, the five patchers `families-c.json` pins, as -51;
- amix at `e45b061` (amix-dlm's history: the module core and `make kit`, as -51) and at `fce38f4`
  (`kernel/k30/tools` and `kernel/k30/contracts`: the sddevsize and W-D7 injectors, `emit-family-chains.py`,
  `k0-gates.py`; until -51 these came from amix-kerntools `bd091b4`);
- amix-paula at `62fdcab`; gcc-cross-amix at amix's `toolchain/gcc-cross-amix.pin` (gcc 2.7.2.3, `8949028`);
  amigaux/amix-system's `kernels/2.1c/unix`; NetBSD 10.1's `syssrc.tgz`;
- optional: the frozen candidate-3 kernel (`5aa7d732`) that emit and k0-gates compare against.

The build is stamped `68060-261031-52`: `SOURCE_DATE_EPOCH=1793404800` (2026-10-31), the build sequence seeded
`261031 51`, and the block lookup pinned to 50-99. (`68060-261031-51` is not a cut: it was the stamp of the
quirk-92 experiment kernel, -51's recipe with the guard linked onto the base, so the cut skips it.)

Against -51 (`18fb7e63`): the kernel adds `src/freeqguard.c` (.text +204 bytes, .data +20) and every relocation
that named `freeq` (qdetach, strclose ×2, stropen ×2) now names `freeq_guarded`; kabi k46.1.3 and its abi are
unchanged. The ufs object is -51's; the module differs in its build id only.

`cut.sh` reproduces all seven sums outside any git checkout (two runs, with the control kernel; k0-gates ALL
GREEN, `ksymgate` 12 of 12 on the shipped form, `mkabi --check` no moved line). With `FREEQ_GUARD=0`, -51's
recipe at `fff9660` gives -51's seven sums, byte for byte (`STATUS_ALLOW_NO_FREEQ_GUARD=1` for its status
gate). Verified in emulation (an A4000 with a 68060): see ISSUE-109. Hardware acceptance on the A4000T follows.
