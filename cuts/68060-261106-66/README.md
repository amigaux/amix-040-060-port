# Cut 68060-261106-66

The k46 module kernel, kabi k46.1.4 (abi 18c0a1c9), cut from this repository's `k46-module` at `512a99f` and amix
`46ef7d1`: the recipe of -65 (`../68060-261106-65`) with the audio driver fixed.  (`512a99f` is `67c347c`, where the fix was
made, with the audio pass refusing a bad `AUDIO_REPLIES`; it builds the same bytes.)

- **/dev/audio answers each volume or period request once, refuses a zero-length one, and plays each byte once**
  (`src/patch_audio_replies.py`; ISSUE-122).  The stock driver sent every AUDIO_VOLUME and AUDIO_PERIOD reply twice
  (a refusal arrived as success); a zero-length I_STR request called `pullupmsg` on a missing block, which on this line
  is a kernel panic (a bus error in `xmsgsize`); and a write longer than its free channel buffer replayed one stretch
  of itself for good.  The patcher runs after amix-paula's three in `relink-040-audio.sh`, its input (1f43c5ff) and
  output (3f434f35) pinned by SHA-256; it is the 030 line's file, byte for byte.  `AUDIO_REPLIES=0` builds without it
  (any value but 0 or 1 is refused).  Of the two refill places, the one for a queued message that straddles a buffer's
  end is fixed by reading only: the proof's writes are single writes, which refill through the other.
- A TCP close fix (ISSUE-118) was tried for this cut and reverted (`7a4a30c`): see KNOWN-ISSUES.

| File | What |
|---|---|
| `SHA256SUMS-68060-261106-66` | the eight files of record, paths relative to the cut's run root |
| `cut.sh` | the recipe: `cut.sh OUT` with the inputs in its header; its sums must equal the file above |
| `build-c.sh`, `post-c.sh`, `families-c.json` | -65's, the core at `46ef7d1` |
| `stamp_buildid.py`, `blocks.py` | the build-id stamper shim (one stamp, at the fpe pass) and the block pin |
| `ufsmod/` | the ufs module's build directory (`$build` this cut's) |

The build is stamped `68060-261106-66`: `SOURCE_DATE_EPOCH=1793923200` (2026-11-06), the build sequence seeded
`261106 65`, the block lookup pinned to 50-99.

## What differs from -65

The base (`b-new` 555b5e5f) is -65's: the audio driver is compiled and linked later in the chain
(`relink-040-audio.sh`).  The kernel's `.text` grows by 88 bytes (the driver's eight changed places), so the kernel moves
from the driver on; its `.data` is the same size.  The ufs objects (`ufs-exp.k46` 1a147403, `ufs-exp-qz.k46` 006f1c9c,
`ufs-exp-hf.k46` 1efb27a0) are -65's; `ufs.mod` differs from -65's in its build id only (one byte).  The abi is -65's;
the kabi differs in its build, size, sha256 and the ident, arena and ksym addresses.  The patcher's `--selftest` runs in
the build and passes (8 places; 10 refusals, each pin alone among them).

## Proof (emulation, A4000 with the 68LC060 on the Z3660)

The kernel and module of this recipe's trial run (the same recipe at `67c347c`; its sums are the record, and a run at
`512a99f` gives the same), installed as
generation 2 by `kbootset`; sound_output=interrupts, period 200; the 68030 line's test programs `audioctl2` (50 rounds
of each request form, each call under alarm(10)) and `aurep2` (one write whose 256-byte ramp names its chunks, every
channel buffer load read through `/dev/kmem` at the live `audio_channel`, `audioinfo` + 0x10):

- **ISSUE-122.**  -65: a zero-length VOLUME request panics the kernel (`PANIC: KERNEL FAULT ... pc=0x805032C`, xmsgsize,
  bus error); a wrong-length one returns 0 in 100 of 100; a 32 KiB write never drains (87 buffer loads in 30 s, 86 of a
  chunk already loaded).  -66: zero length and wrong length EINVAL, 100 of 100 each, the box carrying on; the right
  length and the transparent form 0, 100 of 100; the 32 KiB write drains in 1466 ms with 3 loads, none repeated.
- **No regression** against -65's rows: the sparse-hole test 0 wrong in all three modes; the file test at 128 MiB (a
  144 MB file, 400000 operations) 0 bad; the dd probes past the 64 MiB boot slice's end ENXIO (read 512 B, read 1 MiB,
  write 512 B) with nothing asleep.
