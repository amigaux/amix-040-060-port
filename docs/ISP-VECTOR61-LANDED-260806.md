# F2 landed — vector 61 immediate-multiply unit, emulator-accepted on both CPUs

**2026-08-06.** Implements `amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md` (Codex).
Image `68040-260806-02`, textsize `0xe4a64`, `check_relink_relocs.py` clean.
Hardware run still pending.

> **Update 2026-08-09** — the immediate-only unit was widened to add the `Dn`, `(An)` and
> `(d16,An)` source modes after wolf3d died on `muls.l (12,%a6),%d1:%d2` on real hardware.
> Hardware-accepted (`isp61ea` 7/7).
>
> **Update 2026-08-29** — the three remaining reachable source modes are now decoded:
> `(xxx).L` absolute (7/1), `(d8,An,Xn)` brief-format indexed (6/n) and `(d16,A7)`. The
> accepted set below is superseded by the "Accepted set as of 2026-08-29" section near the end
> of this document; the immediate-only text in *What it does* is the original F2 record, kept
> for lineage. 64-bit DIVIDE stays declined — the compiler routes it through
> `__udivdi3`/`__divdi3` and never emits the hardware form.

## What it does

> Historical (F2, 2026-08-06). See the 2026-08-09 and 2026-08-29 updates above and the
> "Accepted set as of 2026-08-29" section below for the current scope.

`src/isp61_060.s` emulated, as first landed, exactly one instruction form on the 68060:

```text
MULU.L #imm32,Dh:Dl        opword 0x4c3c, extension bit10 = 1
MULS.L #imm32,Dh:Dl
```

That is not a guess about what is needed — it is the measured scope. F0's encoding-based scan
of the installed guest binaries found 103 vector-61 instructions, **all of them this form**
(68 unsigned, 35 signed), with `libc.so.1`, `ld.so.1`, `as` and `ld` completely clean. So one
addressing mode revived the whole installed compiler. Everything outside the accepted set —
register/memory sources not in the set, 64-bit divide, CMP2/CHK2/CAS2, supervisor origin, trace
mode, a failed instruction fetch — takes a **counted, state-preserving** fallback to the
existing `nullvect` SIGKILL path. Nothing is partly decoded and nothing is silently approximated.

Wiring: `patch_isp_vec61.py` retargets the `M68Kvec[61]` relocation from `nullvect` to
`isp61_vec`, deriving the field from the `M68Kvec` symbol. It runs **after** the optional FPSP
block, so an FPSP `ld -r` cannot supersede it and `FPSP=0`/`FPSP=1` images behave identically.
No FPSP script reads slot 61 (they own 11, and 48/51–55). The script also asserts vector **60**
is still `nullvect` before touching 61 — a cheap independent check that we are looking at the
vector table and not merely at the right offset.

## Acceptance, both emulator CPU configurations

`test-tools/isp61test.c` + `isp61test_asm.s`: five raw-encoded multiplies, each preceded by
`CCR = 0x10` (X set) and followed immediately by a canary increment.

| case | ext | operation | Dh:Dl | CCR |
|---|---:|---|---|---:|
| U1 | `0x1400` | `MULU`, `0xffffffff * 2` | `00000001:fffffffe` | `0x10` |
| U2 | `0x0401` | `MULU`, `0xffffffff * 0xffffffff` | `fffffffe:00000001` | `0x18` |
| UZ | `0x2400` | `MULU`, `0x12345678 * 0` | `00000000:00000000` | `0x14` |
| S1 | `0x2c01` | `MULS`, `-3 * 7` | `ffffffff:ffffffeb` | `0x18` |
| S2 | `0x1c02` | `MULS`, `0x80000000 * -1` | `00000000:80000000` | `0x10` |

**68040 (emulated): 5/5 PASS by hardware execution, every `isp61_*` counter ZERO.** That is the
strongest available check that the `cputype` gate holds — the vector is installed, and ordinary
040 execution never enters it. It also makes the 040 run the *reference*: those CCR values come
from real 68040 multiply hardware, and the 060 handler has to reproduce them bit for bit.

**68060 (emulated): 5/5 PASS, and the counters are exactly the pre-registered numbers:**

```text
isp61_entry_n  5      isp61_unsupported_n   0      isp61_last_pc   0x800004DC  (= S2's site)
isp61_ok_n     5      isp61_ifetch_fail_n   0      isp61_last_insn 0x4C3C1C02  (= S2's opword:ext)
isp61_mulu_n   3      isp61_nonuser_n       0
isp61_muls_n   2      isp61_badframe_n      0
                      isp61_trace_decline_n 0
```

Every canary read exactly 1, which is what rules out both a retry loop (canary > 1) and a
wrong PC advance (a `+4` would have executed the immediate as opcodes).

## The bug the test caught, and why it matters

The first 060 run reported **five clean successes in the counters while two of five results
were wrong** (U2 and S2). That is precisely the failure mode counters cannot see, and it was
mine, not the emulator's:

```
	movew	%a5@(2),%d1		| extension word
	...
	andiw	&7,%d2			| Dl
	lsll	&2,%d2
	lea	%a6@(0,%d2:l),%a4	| &saved Dl  <-- LONG index
```

`movew` writes only the low half of `d1`, so its **upper half was whatever `copyin` left
there**. `andiw` masks only the low word, but `lsll` and the `%d2:l` index use all 32 bits — so
the saved-register slot address depended on stale bits. Three cases happened to land correctly
and two did not, which is exactly the shape of a latent register-hygiene bug. Fixed by
zero-extending the extension word (`moveq &0,%d1` before `movew`) and using long masks.

Two lessons worth keeping:

* **`isp61_ok_n` means "the handler believed it succeeded", not "the answer was right."** Only
  the pre-registered product and CCR table separates those. Codex's insistence on exact values
  rather than "the counters moved" is what caught this.
* **S2 is the load-bearing case.** `0x80000000 * -1 = 0x00000000:0x80000000` must leave N
  CLEAR, because N comes from bit 63, not bit 31. A handler taking N from the low longword
  passes the other four.

## Implementation notes worth remembering

* **Shift immediates on the 68k are 1..8**, so a 12-bit right shift is not encodable — the Dl
  field is extracted with `rolw &4` plus a mask.
* **gcc 2.7.2.3's inline assembler mangles mnemonics** (`movel` → `movl`, `moveq` → `mov`) as
  soon as the asm block has operands, and then fails to assemble. The test's raw encodings
  therefore live in a standalone `.s` file, which is assembled verbatim.
* The success path returns through `ureturn` in the `fpsp_done` shape (push USP, set
  `u.u_ar0`, reload USP, jump), never a bare `rte` — otherwise STREAMS qrun, `cl_trapret`,
  signal delivery and the user CACR reload would all be skipped.

## Not yet established

* **Hardware.** Amiberry may execute what real silicon traps, so its 060 is a regression gate
  only (campaign rule 4). What the emulator *did* show is that the handler is entered, decodes,
  computes and resumes correctly — the architectural question of whether a real 68060 delivers
  this frame the same way is the hardware run's job.
* **The negative test** is written (`test-tools/isp61neg.c` + `isp61neg_asm.s`). It was
  originally a register-source 64-bit multiply, but the 2026-08-09 EA widen made that form
  *emulated* (the `Dn` mode), so the decline path lost its falsifier. **Re-pointed 2026-08-29**
  to a 64-bit `DIVU.L #2,%d1:%d0` (`0x4c7c`, ext bit 10 set) — outside the accepted multiply
  family, so it declines by the opword and increments `isp61_unsupported_n`. Real-060 only: the
  68040 retires the 64-bit divide in hardware (verified under qemu-m68k: SURVIVED,
  remainder:quotient `00000000:80000000`).
* **The page-crossing fetch case** (opword at `page+0xffc` so the immediate lands in the next
  page) is likewise unwritten. It is what justifies the single 8-byte `copyin`.
* **End-to-end gcc** — rerunning the `cpp` and `cc1` invocations that faulted at `0x80006ED6`
  and `0x80021530`. That is the payoff, but it cannot replace the checks above.

## Artifacts

```text
src/isp61_060.s          the handler
src/patch_isp_vec61.py   M68Kvec[61] -> isp61_vec, after the FPSP block
relink-040.sh                   assembles, links and patches
test-tools/isp61test.c          the five-case acceptance test
test-tools/isp61test_asm.s      its raw encodings
test-tools/isp61ea.c            addressing-mode acceptance (extended 2026-08-29)
test-tools/isp61ea_asm.s        its raw encodings (extended 2026-08-29)
test-tools/isp61neg.c           decline-path falsifier (re-pointed 2026-08-29)
test-tools/isp61neg_asm.s       its raw encoding (re-pointed 2026-08-29)
test-tools/scan060.py           encoding-based 060-unimplemented-instruction scanner
kernel  build/unix-040  68040-260806-02  textsize 0xe4a64
```

## Accepted set as of 2026-08-29

`src/isp61_060.s` now decodes seven source addressing modes for `MUL[US].L <ea>,Dh:Dl`
(signedness preserved via extension-word bit 11), and declines everything else, counted. The
PC advance is computed from the encoding length (4, 6 or 8 bytes), never a constant.

| mode | encoding | length | added | source |
|---|---|---:|---|---|
| `#imm32` (7/4) | `4c3c` | 8 | 2026-08-06 | constant multiplier |
| `Dn` (0/n) | `4c0n` | 4 | 2026-08-09 | register operand |
| `(An)` (2/n) | `4c1n` | 4 | 2026-08-09 | pointer deref |
| `(d16,An)` (5/n, n≠7) | `4c2n` | 6 | 2026-08-09 | frame local via A6 |
| **`(xxx).L` (7/1)** | `4c39` | 8 | **2026-08-29** | non-PIC global/static |
| **`(d8,An,Xn)` (6/n)** | `4c3n` + brief | 6 | **2026-08-29** | variable-index array element |
| **`(d16,A7)` (5/7)** | `4c2f` | 6 | **2026-08-29** | frame local when A6 is not the frame pointer |

Declined, counted: `(An)+`/`-(An)` (writeback), bare `(A7)`, full-format index words (bit 8),
address-register indices, `(xxx).W`, `(d16,PC)`/`(d8,PC,Xn)`, CMP2/CHK2/CAS2, and the entire
divide group.

### The three new encodings, as the compiler emits them

`m68k-cbm-sysv4-gcc -O2 -m68040 -c`, disassembled (byte-identical at `-m68020/030/040`):

```text
mulu.l g_b,%d1:%d2                 4c39 2401 0000       (xxx).L absolute
mulu.l (%a0,%d1.l*4),%d2:%d3       4c30 3402 1c04       (d8,An,Xn) brief format
mulu.l (12,%a6),%d2:%d3            4c2e 3402 000c       (d16,A6) — reg 7 is the same insn, 4c2f
```

`(xxx).L` is what non-PIC globals compile to; under `-fpic` the same operand becomes a GOT load
and arrives as `(An)`/`(d16,An)`. The `(d16,A7)` form is the `(d16,An)` mode naming A7; gcc
2.7.2.3 tends to load SP-relative operands into a register first, so it is decoded defensively
and covered by hand-encoded tests rather than a compiler sample.

### The A7 stack-safety question

A7 is the user stack pointer and is **not** in the kernel's 60-byte D0–D7/A0–A6 save block, so
its value must be recovered another way. It is read inline with a single `move %usp,An`: the
trap came from user mode and the unit has not touched USP, so the register still holds the exact
user SP the faulting instruction saw. That read cannot fault and pushes nothing, so the
transactional rule (nothing that can fail runs after the first commit; every decline leaves the
frame byte-identical) holds **without a helper call**. An earlier draft reached a helper by
`bsr`, which would push a return address onto the supervisor stack inside the scratch/decode
window — avoided here precisely so the transactional window stays clean.

### Verification (2026-08-29)

* **Encodings + reference products** — the three new modes were assembled from the exact
  `.word` sequences in `isp61ea_asm.s` (via `m68k-linux-gnu-as`, the repo's own recipe for that
  file) and executed **natively** under `qemu-m68k` (a CPU that retires the 64-bit multiply):
  `abs 0b00ea4e:242d2080`, `index ffffffff:ffffffc1`, `d16a7 fffffffe:00000001`, each equal to
  independent host 64-bit arithmetic. The full `isp61ea` battery is 10/10 (`bad=0`), with the
  three new cases placing the operand at the exact effective address and poisoning the
  neighbouring slots, so a mis-decoded index/scale/displacement/base is a wrong product.
* **Decode arithmetic** — the brief-format EA computation (the load-bearing new logic:
  `rolw` field extraction, W/L sign-extension, scale shift, signed `disp8`) was run as a
  standalone routine under qemu across all four scales and negative word-indices/displacements,
  matching a host reference exactly.
* **Handler scans clean** — `m68k-cbm-sysv4-gcc -m68040 -c` of the modified handler, then
  `scan060.py` over its disassembly: **0** 060-unimplemented integer instructions (the only
  multiplies are `muluw`, the 16-bit lmul core).
* **Divide need not be emulated** — the cross `libgcc.a` scans clean (0 hits); `__udivdi3` /
  `__divdi3` / `__muldi3` are library routines, so the compiler never emits the hardware 64-bit
  divide.
* **Counters** — `isp61_abs_n`, `isp61_index_n`, `isp61_a7_n` were appended at the end of the
  `.data` block (offsets `0x3c`/`0x40`/`0x44`), preserving every previously published offset.

### Bench and metal

Consistent with campaign rule 4 and the v60 lane: **the emulator bed does not raise vector 61
for these forms.** Both Amiberry (documented: "Amiberry executes the instruction rather than
modeling the real 060 trap", `docs/contracts/ISP-VECTOR61-UNIT-SPEC.md`) and `qemu-m68k` (observed
here) retire the 64-bit multiply in hardware, so neither exercises the handler's decode path.
Acceptance is therefore **real-060 only**, exactly as the original F2 landing was.

Metal-family artifacts built this round (branch `isp61-mul64`, cross toolchain
`m68k-cbm-sysv4` gcc 2.7.2.3 / binutils 2.8.1, `reloc validation: 0 complaints`, linked
`isp61_vec` region re-scanned clean):

```text
build/unix-040       68040-260829-50   sha256 cafa1f8950f2acd66cf313cd3e32b16923795653d6752ef87a34a5e44aaf9b0f
build/unix-040-fpe   68040-260829-51   sha256 e3fa04c6fe98e94b7e01148b183fb08b39a5a23be2ab28ccb7e222e9a1841552
```

Metal deploy/verify plan (for when the box is powered up):

1. Rebuild (or reuse the shas above) the 060 kernel from this branch — `relink-040.sh` then
   `relink-040-fpe.sh` (`AMIX_ALLOW_UNKNOWN_STOCK=1`), or the r10-class gate battery.
2. Cross-build the guest tools on the host (the guest `/usr/bin/cc` itself dies on vector 61):
   `m68k-linux-gnu-as -m68040 isp61ea_asm.s -o isp61ea_asm.o` then
   `m68k-cbm-sysv4-gcc -m68040 -o isp61ea isp61ea.c isp61ea_asm.o`; likewise `isp61neg`.
3. On the 060: run `isp61ea` — expect **10/10 OK**, with `isp61_abs_n +1`, `isp61_index_n +1`,
   `isp61_a7_n +1`, `isp61_mem_n +5` (the three new + `(An)` + `(d16,An)`), `isp61_reg_n +1`,
   `isp61_ok_n +10` across the accepted cases (`postinc` declines: `isp61_unsupported_n +1`).
4. Run `isp61neg` — expect **SIGKILL** (`vector 0xF4`), `isp61_entry_n +1`,
   `isp61_unsupported_n +1`, `isp61_ok_n +0`. On a 68040 the same binary prints
   `SURVIVED 00000000:80000000`.
5. End-to-end: recompile a global/array/stack-local multiply TU with `/usr/bin/cc` and confirm
   it no longer dies on vector 61.
