# Cut 68060-261103-61

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `a483e89` and amix
`46c269c`: the recipe of [`68060-261102-60`](../68060-261102-60/README.md) with one change, ISSUE-114.

- **A 68040 keeps the pending write-backs of an unresolved user fault** (`src/wbkeep040.s`, `relink-040.sh`
  `WBKEEP=1`). On an access error the 68040 does not re-run the faulted store; the format-7 frame carries it in
  WB1-WB3 and the kernel completes it (`src/wb040.s`), until now only when the fault resolved. A fault that ends in
  SIGSEGV dropped it, so a handler that repairs the mapping and returns -- stock `sh` grows its heap this way --
  resumed after a store that never happened. `usrxmemflt` now keeps those write-backs (eight records, keyed by the
  address space, the USP and the PC), and the wrapped `restorecontext` replays them through `wb040_replay` when
  `setcontext` restores exactly that context; a replay denied again re-signals and keeps the rest, as the 68030 and
  68060 re-run the store; the wrapped `as_free` drops an address space's records.
- **`src/hgfault040.s` is not linked** (`HGFAULT` follows `WBKEEP`): ISSUE-10's break grow completed such a store by
  growing the break inside the kernel, and the program's own next `brk` took the page back with the store in it --
  `sh`'s arena sentinel, then `User BUS ERROR at 3` and `sh: no space` (`ifup -n` in the installer).
  `usrxmemflt_orig` is the stock body at `0x5aede` again.
- The replay-denied console notice (`DBG wb040 replay UNRESOLVED`) is assembled only with `KDBG=1`; the
  "unresolved fault dropped a pending write-back" warning is printed only for a store that was not kept.

| File | What |
|---|---|
| `SHA256SUMS-68060-261103-61` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -60's |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261103-61`: `SOURCE_DATE_EPOCH=1793664000` (2026-11-03), the build sequence seeded
`261103 60`, the block lookup pinned to 50-99.

## What differs from -60

`WBKEEP=0` builds -60's base byte for byte (`23465eb4`). Symbol by symbol against -60's base (as -59's README
describes the comparison): `restorecontext` and `as_free` (the wrappers; the stock bodies, unchanged, are
`restorecontext_orig` at `0x58d76` and `as_free_orig` at `0xadf9a`), `wbk_save` and the records, `usrxmemflt` and
`Lu_wbdenied` (the two hooks), `Lu_replay` and `wbf_dropwarn` (the replay depth word), `Lwbf_nonat` (the notice
assembled out), `usrxmemflt_orig` (the stock body again), and `hgfault040.s`'s code and counters gone; the rest
differ in extent only. The base's `.text` grows by 168 bytes and its `.data` by 304. The abi and the ufs objects are
-60's; the kernel, the kabi and the ufs module differ by the build id and the base.

`cut.sh` reproduces all seven sums in `amix-toolchain:dist` with the control (k0-gates ALL GREEN); `ksymgate` 12 of
12 on the shipped form, `mkabi --check` no moved line, `tools/status-facts.sh` with `restorecontext` and `as_free`
bound.

## Proof

`test-tools/wbkeep.c` (`wbkeep -j 20`) stores a byte, a word, a long, and a long and a word across a page boundary
into a read-only page whose SIGSEGV handler makes it writable and returns; a long one page past the break, then
the same followed by the program's own `sbrk`; and twenty stores whose handler `longjmp`s out. Every store must land,
the abandoned ones must not, and the kernel's records must go with the process. It prints `WBKEEP PASS` and exits 0.
On -60 a 68040 loses all five repaired stores; the 68060 passes either way.

The binary of record is built from `a483e89`'s `test-tools/wbkeep.c` with `m68k-cbm-sysv4-gcc -m68040 -O -o wbkeep
wbkeep.c` in `amix-toolchain:dist`: 6806 bytes, sha256 `94fdb90c8e9d3e5240df46744e09086b4a140ab6c171fb24becf2d9ed05b6ae7`
(`sum -r` 32950 14 on the box). Its 25 intended faults (the five repaired, the twenty abandoned) each log one
`User BUS ERROR at <addr>, PC:<pc> FAULT:6 ... CMD:/tmp/wbkeep -j 20` line; the two brk cases log none.

In emulation, on this cut's image (4d23c99b):
- An A4000 with a plain 68040 (the A3640 model), 16 MB, the root on the A4000 IDE (an installed 1.1 disk with this
  kernel as a new generation): `wbkeep -j 20` WBKEEP PASS; `sh -n` on the installer's `install.sh` and `setup.sh`,
  each cut before its first top-level loop (114 747 and 92 825 bytes; stock `sh -n` never leaves a top-level `while`)
  and with their `:?`-guarded variables set, rc 0 twice each -- ISSUE-10's parse-time repro; `ifup -n` rc 0; a
  10 201-byte `sh` string built in a loop three times; `sh -c 'set -- *'` in `/usr/bin` (310). Kept stores replayed:
  `wbk_saved_n` 0x12f, `wbk_replayed_n` 0x11b, the difference the twenty abandoned ones refreshing one record that
  went with its process (`wbk_freed_n` 1); `wbk_live` 0, `wbk_full_n` 0, `wbf_dropped_n` 0, the kernel log empty.
  The 25 `User BUS ERROR` lines are all `wbkeep`'s; sh, `sh -n` and `ifup` logged none.
- The A4000 row with the 68LC060 on the Z3660 (N241a's shape), this cut installed by `kbootset` and booted: the same
  set (no `ifup` on that image), all passing; every write-back counter stays 0.
On -60, the same 68040 row loses every repaired store, `sh` ends `no space`, and `ifup -a` at boot floods the console
with `User BUS ERROR at 3, PC:800023EE`.
