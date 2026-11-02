# Cut 68060-261102-60

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `422efc5` and amix
`46c269c`: the recipe of [`68060-261102-59`](../68060-261102-59/README.md) with four changes.

- **`sdqueue` at IPL 2 at least** (`src/sdqspl040.s`, `relink-040.sh` `SDQ_SPL=1`; amix-dlm C2-4 version 24
  section 18). dd, sdpart and ct call `sdqueue` at `sdspl()`; scsi.c's `gsioctl`, the `/dev/scsi` pass-through,
  calls it at spl0. As the stock a3091 driver's first command that lets the WD33C93's reset interrupt in during
  `initialize()`: `a3091intr` reads SS 0x01 while IDLE, prints `a3091: 0x1 0 0x0`, the controller is DEAD and the
  command never completes. The wrapper takes the strong `sdqueue`, raises to IPL 2 only when called below it,
  calls the stock body (kept at `.text 0xd6f6` as `sdqueue_orig`) and restores SR only if it raised. The 68030
  line's rule. `SDQ_SPL=0` builds without it (at `553657e`, before the pstart change, that rebuilt -59's
  base byte for byte).
- **The A1200's Gayle port is motherboard id 2** (`src/rth1.c` `rth1_moboid`, `src/kinfo.c` `kinfo_build`): the sd
  name `A1200 IDE` maps to the id `A4000 IDE` has, one id for either port, the root record's key (amix-dlm C4-1
  section 5.2).
- **pstart's CACR/Ramsey boot dump only with `btrace_on`** (`src/pstart040.s`): the read of the Ramsey control
  byte at `0xDE0003` ran on every boot for a line printed only when tracing; an A1200 has no Ramsey.
- **`cputype` from the k46 loader's AXL1 record** (`src/pstart040.s`). The image ships with `cputype` stamped 60
  (the KD060 chain) and amix-dlm's boot2 does not poke it as the old unix_boot040 did; it hands its own CPU
  probe's result in AXL1 (`bootinfo`+0x6b0, field +20). At its entry pstart validates the record (magic `AXL1`,
  version/length 0x0001007c, the 31 longs summing to 0) and takes cpu 60 or 40 before the first `cputype` test;
  otherwise the stamp stands. Without it a 68040 ran the 060-only `movec %pcr` in pstart and died at once.

| File | What |
|---|---|
| `SHA256SUMS-68060-261102-60` | the seven files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs below; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -59's |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261102-60`: `SOURCE_DATE_EPOCH=1793577600` (2026-11-02), the build sequence seeded
`261102 59`, the block lookup pinned to 50-99.

## What differs from -59

Symbol by symbol (as -59's README describes the comparison): `sdqueue` (now the wrapper; the stock body is
`sdqueue_orig`, its bytes unchanged at `0xd6f6`) and the wrapper's labels; `pstart` (the AXL1 read and the `btrace_on` test, with their
labels); `rth1_moboid` and three rth1 functions
whose relocations name `rth1.c`'s function-local statics, which the compiler numbers in order and the new
`gayle1200` renumbered; `kinfo_build` and its strings; the build id (`buildid`, `dlm_ident`). Nothing else.
The abi, both ufs objects and the kit are -59's; the ufs module differs in its build id only.

`cut.sh` reproduces all seven sums in `amix-toolchain:dist` with the control (k0-gates ALL GREEN) and without it
(the one refusal is the missing control); `ksymgate` 12 of 12 on the shipped form, `mkabi --check` no moved line,
`tools/status-facts.sh` with no failing binding (`sdqueue` among them). Host tests: `tools/test-rth1.sh` and
`tools/test-kinfo.sh` pass with an A1200 case each.

In emulation, on this cut's image (7f217425):
- The first-use race on an A3000 with its own ECS chipset, a 68LC060, the root on the Z3660 and a 200 MB scratch
  disk at WD unit 5 that the boot never touches. The WD's first command after boot is `kbootset inquiry 1 5`
  through `/dev/scsi`, at spl0, run in the background. It answers at once (`type 0 UAE scratch.hdf`), and after
  it a raw write and read-back on the WD compare equal, `swap -a`/`swap -d` on the WD and exectest pass. -59 on
  the same row and script stops answering at that inquiry (the telnet session times out three times over, no
  clean halt): the first-use hang, whose console line the 68030 line's run of the test printed as
  `a3091: 0x1 0 0x0`.
- The A4000 row (N241a) with -59's whole set: tdemand, the zero page and nullread, the 16 pm probes, exectest 20
  and 40, leaktest 60, swap and paging on the scratch slice, fpebench; PASS.
On these 68060 rows AXL1 reports cpu 60, the stamped value, so the cputype change is exercised there only as no
change; a 68040 boot is its test.
