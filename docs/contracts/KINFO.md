# `/dev/kinfo` and the kabi sidecar: the kernel half on the 68040/68060 line

**Status:** implemented on the driver line, 2026-10-25. The record is defined by the kernel-modules project's
contract C2-1, version 3 (`amix-dlm`, `docs/contracts/C2-1-kinfo.md`), and the sidecar by its C2-3
(`docs/contracts/C2-3-packages.md`). This file says how a kernel of this line fills them. Where the two disagree,
C2-1 and C2-3 win.

**Why it exists.** A program on a running box cannot tell which kernel booted it, which loader record it got,
or which disks sd numbered as which card. The installer, the package tool and a boot-generation manager need
all three. A read-only character device gives them one record, the same on every kernel family.

## The device

- Character major **53**, minor 0. The node is `mknod /dev/kinfo c 53 0`, mode 0444.
  - Majors 49 to 52 belong to zz9000, sad, z3660eth and monsw, 67 to xsvga and 68 to va2000.
  - `src/patch_kinfo_cdevsw.py` asserts that row 53 is free on the whole row before it takes it, by the same
    test `src/patch_monsw_cdevsw.py` uses.
- `read(2)` returns the record's bytes from the file offset up to its length, then 0.
- `lseek(2)` works as on any character device.
- `write(2)` fails with `EPERM`.
- An open of any minor but 0 fails with `ENXIO`.
- The record is built on the first open, from the kernel's own copy of `bootinfo`. `config()` makes that
  copy, and nothing in the kernel writes it afterwards.
  - Before it reads sd's card table it calls `sdopen(0)`, because sd's `init()` is lazy (as in `src/rth1.c`).
  - On a static kernel nothing in the record changes after that.

## The record, version 3: how this line fills each field

The layout is C2-1 §2: big-endian, 580 bytes with no modules.

| Offset | Field | Source on this line |
|---|---|---|
| 0 | magic `KIF1` | |
| 4 | `3 << 16 \| length` | length = 580 + 32 × modules = 580 |
| 8 | check | set last, so all 145 longwords sum to zero |
| 12 | CPU | the kernel's `cputype` global: 40, or 60 on a 68060 |
| 16 | line | 46 |
| 20 | `AttnFlags` | from the AXL1 record (its offset 24) when one arrived, else 0. The kernel has no other copy |
| 24 | kabi tag | `kinfo_kabi` in `kinfo.o`'s `.data`: `static`. The sidecar's `kabi=` is read from the same bytes |
| 48 | build id | `inituname040`'s `buildid` without its leading space, as `uname -m` ends: `68060-261025-50` |
| 80 | flags | 0x1 AXL1 found, 0x2 RTH1 found, 0x4 safe mode (AXL1 flag 0x01), 0x8 the bootdata's text vaddr is not the kernel's own `stext` (a loader fault: `stext` is `.text`+0 on this line) |
| 84 | AXL1 | `bootinfo + 0x6b0`, 124 bytes, copied only when it has magic, version 1, length ≥ 124 and its 31 longwords sum to zero; else zeros and flag 0x1 clear |
| 208 | RTH1 | `bootinfo + 0x678`, 0x38 bytes, under the checks `src/rth1.c` applies; else zeros |
| 264, 268 | boards | `bootinfo.autocon[]` in order, every slot that has a manufacturer or a board address |
| 460, 464 | sd cards | sd's controller array (`sd_queue_tbl`), slot k = card k (see below) |
| 528 | fast memory | `VSIZOFMEM`: the size of the contiguous region the kernel runs in, as `config()` sized it |
| 532 | chip memory | `chipmem` |
| 536 | bootdata | `bootinfo + 0x650`, 40 bytes verbatim: entry, then text, rodata and data vaddr, offset, size. boot2 and stock `unix_boot`'s `rel()` both fill it; it says where the kernel was bound, so a namelist bound to it gives `nlist` the running kernel's addresses |
| 576 | modules | 0 |

**The sd card table.**
- sd's `init()` keeps up to two controllers, sorted by the address it recorded. Slot k is card k, and a disk's
  device name is `c<8k + unit>d0s<slice>`.
- On a kernel built with `relink-040-sd4card.sh` (amix-dlm C4-1) sd keeps four, in rank order: the Z3660, Zorro
  boards by address, the motherboard controller, IDE. Cards 2–3 name their disks `c10`–`c1f`, and the table
  lists up to four cards.
- A card whose address is an AutoConfig board's `cd_BoardAddr` gets the id `er_Manufacturer << 16 |
  er_Product << 8` and that base, with flags 0.
- Any other card is a motherboard controller: base 0, flags 0x1, and an id with a zero manufacturer:
  - 1 = `a3000-wd`, the row named "A3000 Internal SCSI";
  - 2 = `gayle`, the row named "A4000 IDE";
  - 3 = `a4000t-710`, the row named "A4000T onboard SCSI" (amix-a4091's A4000T target);
  - 4 = `z3660-window`, the row named "Z3660 SCSI" when no AutoConfig board is at its address (the
    Z3660 at its window, amix-dlm C4-1 section 5.1); with its board it is `zorro:144b:01`;
  - 0 = not known.
- src/rth1.c names the motherboard cards by the same rule (amix-dlm C4-1 section 5.2).
- The Gayle IDE row hands sd a sort key, not a bus address (`src/ide_sd_glue040.s`). That is why a motherboard
  card reports base 0, not what sd recorded.

**The stock A3000 row.** It answers only when the kernel was loaded above 0x07000000 (`autocon()` in
`amiga/kernel/support.c`). A kernel bound lower lists no A3000 card, even though the A3000 SCSI driver is linked in. For
example, a 68060 rig with a 16 MB fast region boots this way from an A3000 SCSI disk, and only its Z3660 is
card 0.

## The sidecar (C2-3 §2)

`tools/kabi-sidecar.py KERNEL --family NAME` writes one `key=value` per line. Every value except `family` and
`pin` is read from the image, and nothing in it depends on the time.

| Key | Source |
|---|---|
| `kabi` | `kinfo_kabi` |
| `family` | the argument |
| `line` | `k46` |
| `pin` | `gcc-2.7.2.3-<gcc-cross-amix HEAD>`. Refused unless the installed `m68k-cbm-sysv4-gcc` is that commit's wrapper; `--pin` overrides |
| `build` | `buildid`, with `68060-` when the image's `cputype` is 60, as the kernel itself rewrites it at boot. A module kernel's image must already carry the stamped CPU's prefix (`STAMP_BUILDID_CPU=60` at the FPE pass), so `build=` is its own string byte for byte |
| `size`, `sha256` | of the kernel file |
| `loader-min` | 1 |
| `root` | the rows of the controller table sd's `init()` walks: `zorro:<mmmm>:<pp>`, `mobo:a3000-wd`, `mobo:gayle` |
| `rootfs` | `ufs` when `ufs_mountroot` is linked, `s5` when `s5mountroot` is |

- `--stand DIR` writes the package's two files, `DIR/stand/k46/unix` and `DIR/stand/k46/kabi`.
- `--check KERNEL SIDECAR` tests that a sidecar is the one the tool writes for that kernel.
- It runs on the finished kernel, the one that ships, after every post-link stamp.

## Build order

`relink-040-kinfo.sh` runs after `relink-040-rth1.sh` (or any pass that exposes `sd_queue_tbl`), before
`relink-040-fpe.sh`:

    dd -> a3q -> z3660 -> monsw -> zz9000 -> a4091 -> ide -> cdfs -> rth1 -> kinfo -> fpe

Its gates:
- the exact import set and the exact export set;
- no `.rodata`, no COMMON, no name that collides with the base;
- scan060 CLEAN;
- cdevsw[53] free before the pass and registered after it.

## Checking it on a box

- `test-tools/kinfotest.c` builds with the native `cc`. It reads the record and checks the magic, the length,
  the zero sum, an `lseek` to 528 against the whole read, the reads at the end, and `EPERM` on `write`.
- `tools/kinfo-decode.py` decodes a record pulled from the box (or the output of `od -X`) field by field and
  checks its shape.

## The module kernel (2026-10-26)

The k46 module kernel (amix-dlm stage-3 kernel brief, S3-20) carries the module core, spliced in by
`relink-040-dlm.sh`. kinfo and rth1 are built for it with `DLM=1`:

- **kinfo** (`-DKINFO_DLM`). The kabi tag is `k46.1.2` (`k46.1.0` before stage 4, `k46.1.1` at S4-21/S4-22) (`KINFO_KABI` overrides). Every `read(2)` refreshes
  the module list (count at 576, entries from 580) from the core's `dlm_kinfo_list()`, with up to 32 entries,
  and sets the length (580 + 32 × n) and the check to match. Without `KINFO_DLM` the object is the static kernel's, byte for byte.
- **rth1** (`-DRTH1_DLM`). `rth1_mountroot()` calls `dlm_marc_post()` once `vfs_mountroot()` has returned 0,
  so the boot-class modules load in process 0 once the root is mounted.
- Between the two passes and the splice, `dlm_kinfo_list` and `dlm_marc_post` stay open. Each pass names them
  to `check_relink_relocs.py --pending`, and `relink-040-dlm.sh` refuses a base with any other import open.

The chain leaves z3660eth, zz9000 and monsw out (majors 49, 51 and 52 belong to modules):

    dd -> z3660 (Z3660_NET=off) -> f4arms -> f6 -> rth1 (DLM=1) -> kinfo (DLM=1) -> dlm -> fpe
       -> [kerntools sddevsize, W-D7] -> relink-040-dlm.sh --fill -> [emit]

- `--fill` runs after the W-D7 inject, which grows `.text`, and before emit, which only patches `.data` words.
  It also takes the fingerprint: amix-dlm's `tools/mkabi.py --check` against `abi/k46/abi-<kabi>.txt`
  (C3-3 §4). A fingerprint that moved fails the build; `DLM_ABI_NEW=1` writes the new text instead, for the
  one rewrite of a tag's reference that C3-3 allows.
- `cputype` is a DDI data name, so `src/cputype060.s` gives it `.size cputype,4`: the fingerprint carries
  its `st_size`.
- `tools/kabi-sidecar.py` writes the sidecar of C2-3 version 5 for such an image, in C3-3 §3's order:
  - `family=generic` and `loader-min=2`;
  - `ident`, `arena` and `ksym` from the image's own AXK1 record, after checking it;
  - `abi` as `--fill` printed it (`--abi`);
  - last, `root` and `rootfs` as for a static kernel. Through stage 3 the root controllers and filesystems
    stay built in, and kbootset's gate 3 needs them.
    `rootfs` lists only what is linked in (amix-dlm C3-3 version 6), so a cut without ufs and s5 has none.
  - after them, `rth1=2` (C2-3 version 9) when the image's `src/rth1.c` matches a motherboard controller's
    record by its id (amix-dlm C4-1 section 5.2; the image has `rth1_moboid`), on any kernel.

**The cut without ufs and s5 (2026-10-27, amix-dlm S5-11).** `relink-040-carve.sh` runs first, on
`relink-040.sh`'s output, before any pass that branches across the ranges. ufs and s5 become dead and
zeroed in place, so no address moves: `vfssw` loses their rows (`nfstype` 10), `init_tbl` loses
`inoinit`, the relocations inside the ranges go, and every symbol defined there leaves the symbol table
with the COMMONs only they use. ufs then comes from a core-tier module (`tools/fsobj-patch.py`, wrapped by
amix-dlm `tools/carve.py` with the cut's build id); s5 has none on this line. The module's inputs are
the cross sysroot's stock objects: `fsobj-patch.py --stock <stand/unix> --base build/b-new
usr/sys/fs/ufs/exp` (a439e68f), and `carve.py wrap --filesys usr/sys/master.d/filesys.o` (1c7a3ca6).
It is built with amix-dlm's k46 ABI kit at the core's revision, made with `PORT` = this tree and
`MONSW_H` = its `src/sys/monsw.h`.

    carve -> dd -> sd4card -> f4arms -> f6 -> rth1 (DLM=1) -> kinfo (DLM=1) -> dlm -> fpe -> ...
