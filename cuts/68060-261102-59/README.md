# Cut 68060-261102-59

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `e9dcecd` and amix
`46c269c`: the recipe of [`68060-261102-58`](../68060-261102-58/README.md) with the investigation instruments out of
the default build.

- **The base** (`relink-040.sh` at `e9dcecd`) no longer links or patches in the instruments of closed or idle
  investigations, and their counters and A/B words are gone from the hot paths:
  - behind switches, all 0 by default, so each stays rebuildable: `I10` (the ISSUE-10 audit: `src/i10rev040.s`, its
    hook calls in `usrxmemflt`/`krnxmemflt`, the chain counters in `hat040.s`/`hat_dup040.s`, `vtop040.s`'s
    VTOPALIAS probe, the `as_fault`, `brk` and `segvn_faultpage` wrappers), `KDBG` (the VM debug prints gated by
    `kdbg_on`), `DIAG106` (the four ISSUE-106 instruments), `DIAG103` (`segmapdbg`), `KVP` (the `nullvect` census);
  - removed: the per-event counters of the FPE (but `fpe_entry_n` and `fpe_v60_n`), the fault and write-back paths,
    the A3091 interrupt demux, the freeq guard, the hat, the ISP and FPU-context units, page free, allocation and
    zeroing; the A/B words `codepub_on`, `dbg_publish_on`, `ptd_on`, `wb_dfc_on`, `xpage_on`, `hg_on`, `wbn_on`,
    `wbf_prop_on`, `hbu_on` (their fixes always on) and the ISSUE-22 DFC injection hook;
  - kept: every real fix, the counters of failures and anomalies, `fqg_run`/`fqg_scan` (written only when the guard
    takes a queue off), and `pgrsv_calls` at 0 (no longer written; the family contract's pinned
    `patch_pgrsv_sites.py` reads it).
- **The chain** runs no F4 pass: no `relink-040-f4arms.sh --ufault` and no `relink-040-f6.sh --kvd --swa` (`F4=1`
  puts them back; on this base they also need `DIAG106=1`).
- **The sidecar** carries `kbootset-min=` from the core's floor file (C2-3 version 10): `1.1.0.261102-35`.

| File | What |
|---|---|
| `SHA256SUMS-68060-261102-59` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh` | -58's without the F4 passes (`F4=1` restores them) |
| `post-c.sh` | -58's, the sidecar with `--kbootset-min` |
| `families-c.json` | -58's family contract, unchanged |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

Inputs (`cut.sh` names each by an environment variable; all of them public): as -58's, with this repository at
`e9dcecd`. The build is stamped `68060-261102-59`: `SOURCE_DATE_EPOCH=1793577600` (2026-11-02), the build sequence
seeded `261102 58`, the block lookup pinned to 50-99.

## What differs from -58

`out/c/unix` is 2 353 236 bytes against 2 425 212: `.text` 0x10b1f0 (-12 700), `.data` 0x7f060 (-14 652), `.bss`
unchanged. Symbol by symbol against -58 (every `.text`/`.data`/`.bss` symbol paired by name and occurrence; bytes
compared with relocation fields masked and 8/16/32-bit pc-relative displacements re-aimed through the pairing;
relocations compared with section-relative addends resolved to symbol + offset; a symbol whose extent changed
because its neighbour went is compared over the common bytes), every symbol that differs or exists in one image
only is defined in a source file this change touched, or is one of these stock sites:

- `_start`, `stext`, `pstart_2`: the ISSUE-106 user-RTE capture is not patched in (`patch_inituser.py`), so the
  stock bytes and `jsr main` stand (`patch_inittrap.py`);
- `utraps`, `u_trap`, `setregs`, `nullvect`: the stock edges and bodies (no `srg_utraps`, `unt_latch`, setregs latch
  or `nullvect` census);
- `as_fault`, `brk`: the stock bodies (no ISSUE-10 wrapper); `segmap_unlock`: no ISSUE-103 latch;
- `swapconf`: calls `swapadd_guarded` directly (no `swa_latch`);
- the build id (`buildid`, `dlm_ident`, `dlm_ksym`), and the aliases the switches create (`*_orig`,
  `segvn_faultpage_prot`, `swapadd_real`).

Three stock functions (`intret`, `extractarg`, `as_addseg`) differ only in extent, their bytes equal. Nothing else.
The abi, both ufs objects and the kit are -58's; the ufs module differs in its build id only; the base `b-new`
changes (3a3ce586) since the instruments were in it. The sidecar: `build=`, `size=`, `sha256=`, the `ident=`, `arena=`
and `ksym=` addresses, and the new last line `kbootset-min=`.

`cut.sh` reproduces all seven sums in `amix-toolchain:dist` (gcc-cross-amix `33ebadc`, gcc14's binutils 2.43.1 as
`G14` = `/opt/amix/gcc14-cross-amix/build`), with the control (k0-gates ALL GREEN) and without it (the one refusal
is the missing control); `ksymgate` 12 of 12 on the shipped form, `mkabi --check` no moved line,
`tools/status-facts.sh` with no failing binding (the three diagnostic overrides read "not built").

The base built with every switch on (`I10=1 KDBG=1 DIAG106=1 DIAG103=1 KVP=1`) links with no unresolved symbol and
no reloc complaint.

In emulation (Amiberry, `s-c59.sh`, -58 beside it on the same rig): on N241a (A4000, 64 MB) kbootset check, build,
commit and mark-good rc 0; the zero page and nullread SIGSEGV; the 16 pm probes; exectest 20 and 40 PASS; leaktest 60
with no fork failure; `swap -a` and `swap -d` on the scratch slice rc 0 with paging between; fpebench; all PASS. On an
A3000 row (root on the Z3660, a scratch disk on the WD) both kernels pass the same set, but the WD is not in the card
table (`kbootset cards` lists card 0, the Z3660, only), so its raw device answers ENXIO and only the demux's
no-device branch ran (it runs on every level-2 interrupt, the clock among them).
