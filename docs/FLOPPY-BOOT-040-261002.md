# A 68040/68060 kernel from DF0 (2026-10-02)

**Status: EMU proven for a disk-rooted kernel (P3 cell, 2026-10-02). HW: not run. A floppy-rooted
kernel: not built.** This is KT-16 / wave B3 of the 040/060 plan: before it, no floppy could start a
kernel of this line, because both the loader and the kernel's relocations stood in the way.

## 1. Why the stock floppy cannot, and why the fix is framing

The AMIX 2.1 boot floppy is the boot-slice chain laid at offset 0 of the disk: boot1 (the AmigaDOS
bootblock) at `0x0`, an IBLK at `0x400`, the 8192-byte boot2 at `0x600`, the kernel's IBLK at
`0x2600`, and the kernel at `0x2800` as an LZW (`compress -b16`) stream of a brel image (ELF
`e_type 0xff00`). The stock floppy's boot2 is the name-based loader (`5ab360b1…`). It fails on this
line for the two reasons amix-kerntools' `docs/boot2-040.md` gives for the disk loader:
- copyit's `pmove`s are F-line on a 68040/68060;
- `rel.c` knows only `R_68K_32`.

Both are already answered, so a floppy only has to be framed from parts that exist:
- **boot2-040** (amix-kerntools, contract identity `good_040`, sha256 `fd7dacf6…`) is the
  flags-based loader with the CPU dispatch and the PC-relative cases. It is one program for both
  media. Its `boot2.c` reads through whatever device boot1 opened and decompresses when
  `ib_fullsize > 0`, and its `rel.c` takes `ET_LOPROC` (brel) as well as `ET_REL` (`amix-src`
  `amiga/boot/boot2.c`, `rel.c`).
- **elf2brel.py's static apply** (amix-kerntools, wave A2) resolves all 330 PC-relative
  relocations at conversion time, so the brel carries `R_68K_32` entries only.

`tools/frame-floppy-040.py` frames the disk. It keeps the donor floppy's boot1 unchanged, puts
boot2-040 at `0x600` and recomputes that IBLK's checksum, then writes the new kernel payload and
its IBLK. Before writing anything it checks every input: the donor's layout and its three
checksums, boot2's size and sha256, the brel's `e_type`, that the LZW stream round-trips, and the
budget. Afterwards it re-reads the output's layout. The donor and boot2 are the reader's own
proprietary files and are never stored here.

## 2. The cell (EMU, Amiberry fork, rig slot)

Setup:
- **Kernel:** KD060-Z = KT-12g c0-u6 (sha256 `b9cee294…`, sum -r 08512, build id `68040-260929-71`).
- **Conversion:** brel 1 445 660 bytes, LZW 826 176 bytes, 64 704 of 890 880 bytes free.
- **Disk:** `boot040-kd060z.adf`, sha256 `f65d1267…`.
- **Machine:** the matrix row E5 shape (A3000 model, LC060/Z3660, root on piscsi unit 6), emitted
  by `rig-matrix.py` for a leased slot. Two changes: DF0 holds the ADF, and the **A3000 vehicle
  disk is removed**, so Kickstart's only other boot source is the root image's own boot slice. That
  slice holds a different kernel (build `68040-260828-50`), so the build id says which one ran.

Result (cell 2, `Amix/tmp/2026-10-02-p3/cell2/`; cell 1 is the same boot, stopped before its halt):
- console banner `… Amiga (Unlimited) 68060-260929-71 Version 2.1c`;
- `uname -a` = `… 68060-260929-71 m68k`;
- `/ on /dev/dsk/c6d0s1`;
- "The system is halted"; 0 Gary timeouts, 0 illegal accesses.

**What it proves.** boot1 → boot2-040 → decompress → brel relocation → a 060 kernel works from
DF0 under emulation.

**What it does not prove:**
- **metal.** The A4000D's Gotek is the bench for that.
- **a 68040.** No 040 silicon on our benches.
- **a kernel rooted on the floppy.**

## 3. What a 040/060 floppy install still needs (for amix-installng and amix-kerntools)

1. **A floppy-rooted family** (rootdev FD0P `0x00400008`, as `fd0unix` is on the 030 line), from
   kerntools, which stamps rootdev.
   - Untested and open: the stock floppy driver reading the root floppy under this line's cache
     modes. Paula's disk DMA into chip RAM is only safe if the CPU cannot read stale lines, and this
     repository does not record the chip-RAM mapping's cache mode.
   - The emulator cannot settle it: the rig runs with `cpu_data_cache=false`, and Amiberry has no
     copyback model. So the first fd0-root boot belongs on metal.
2. **The budget.** The release KD060-Z leaves 66 048 bytes of 890 880. With cdfs (PO-02) only 14 219
   are left, and with cdfs and IDE only 4 439. An install floppy family without the RTG and monitor
   switch drivers (zz9000, monsw), which the miniroot does not need, gives real headroom. Either
   way, the media build should gate the budget.
3. **The miniroot (root.adf).** The 030 NG miniroot's userland runs unchanged in user mode on the
   060, through the FPSP and the ISP. Its cdfs mount helper needs CD-03's 060 check.
4. **boot1.** The donor's boot1 has no CPU gate. Under boot2-040's 030 path, a 68030 would load an
   040/060 kernel and die in it, so the 040/060 floppy wants the inverse of KT-08's gate (KT-15).
5. **The framer.** installng's `build-universal-bootfloppy.sh` copies the donor's first `0x2800`
   bytes verbatim, which includes the name-based boot2. For 040/060 media it needs boot2 swapped
   and its IBLK checksum recomputed, which is what `tools/frame-floppy-040.py` does.
