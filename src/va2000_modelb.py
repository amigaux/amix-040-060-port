#!/usr/bin/env python3
# va2000_modelb.py -- Model B (4 KiB page frame) adaptation of the MNT VA2000
# driver source for the EXPERIMENTAL 040 va2000 kernel (2026-07-24).
#
# The driver (VA2000_SRC, repo va2000-amix) is a SEPARATE project that also has
# to keep building for the vanilla 68030/2 KiB kernel.  (Until 2026-08-19 this
# header said "DO NOT MODIFY IT"; the Zorro III track does modify it, on its own
# branch, and the pin below is what keeps that honest.)  Against the vanilla
# kernel it has exactly ONE page-size dependency: va2000mmap() returns
# phystopfn(pa) with the stock 2 KiB shift `>> 11` (PNUMSHFT=11).  Our 040
# kernel uses 4 KiB pages (Model B, PNUMSHFT=12), so a VM mapping built from an
# unconverted >>11 value would land at (pa>>11)<<12 = 2*pa -- the same
# device-mmap PFN bug already fixed for scrmmap/ammmap/timmap/svgammap (see
# patch_devmmap_pfn.py / patch_xsvga.py).  Converting the *source* (rather than
# patching the compiled object, since we compile this driver ourselves) is
# cleaner and keeps the object's bytes traceable to a source line.
#
# This script copies va2000.c (untouched) into build/, rewrites the ONE
# `>> 11` in va2000mmap to `>> 12`, and asserts the replacement count is
# exactly 1 -- fails hard otherwise so a silent no-op (source drifted
# upstream) or an over-match is never possible.
#
# Two sources are pinned (PINS below).  Upstream's still has the literal and
# is patched as above.  The va2000-amix fork's `next` takes the shift from
# the kernel's PNUMSHFT, which the Model-B headers make 12, so its file is
# copied unchanged: the literal must be absent and the PNUMSHFT shift present
# exactly once.  Both give the same va2000_040.o bytes.
#
# Usage: python3 src/va2000_modelb.py
#   reads:  $VA2000_SRC
#   writes: build/va2000_040.c   (copy; patched when the source is upstream's)
#   also copies va2000.h unmodified alongside it (va2000.c does
#   #include "va2000.h" and needs it in the same directory to compile).

import shutil
import sys
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The driver source comes from VA2000_SRC in config.sh, which is where check-env.sh looks and
# where BUILDING.md tells you to put it.  Until 2026-08-16 this line held a path under one
# developer's home directory instead, so the configuration variable was decoration: check-env.sh
# reported it green, and the build then read a directory that exists on exactly one machine.
SRC_C = os.environ.get("VA2000_SRC")
if not SRC_C:
    sys.exit("VA2000_SRC is not set.  Point it at your va2000-amix src/va2000.c in config.sh\n"
             "(the graphics kernels are the only thing that needs it; see BUILDING.md).")
SRC_C = os.path.expanduser(SRC_C)
SRC_DIR = os.path.dirname(SRC_C)
SRC_H = os.path.join(SRC_DIR, "va2000.h")
for _p in (SRC_C, SRC_H):
    if not os.path.exists(_p):
        sys.exit("VA2000_SRC points at a tree without %s\n  VA2000_SRC=%s"
                 % (os.path.basename(_p), os.environ.get("VA2000_SRC")))
OUT_C = os.path.join(HERE, "build", "va2000_040.c")
OUT_H = os.path.join(HERE, "build", "va2000.h")

OLD = "        return (int)((va2000_boards[mindev] + offset) >> 11);\n"
NEW = ("        /* Model-B (4 KiB page, PNUMSHFT=12) adaptation of the vanilla\n"
       "         * 2 KiB-page (PNUMSHFT=11) shift -- see va2000_modelb.py header.\n"
       "         * The VM builds the user mapping as (returned_pfn << 12), so this\n"
       "         * must return pa >> 12, not the stock kernel's pa >> 11. */\n"
       "        return (int)((va2000_boards[mindev] + offset) >> 12);\n")


# PROVENANCE PIN, added 2026-07-28 after the user asked the right question: "is the 8-bit display
# mode support in the kernel driver, or is it still only on its own branch?"
#
# It was in -- but only because that branch happened to be the checked-out one.  This script reads
# whatever VA2000_SRC currently points at, with no branch and no revision pinned,
# so `git checkout main` in that repo would silently produce a kernel WITHOUT the 8-bit support and
# no build-time signal at all.  wolf3d needs 8-bit: the branch adds VA2CLR_8BIT, the /2 pitch for
# two pixels per 16-bit word, 2x pixel doubling for small modes, and cur_bpp = 8.  On main the
# driver is 16-bit only ("This driver implements 16-bit only" -- its own comment).
#
# Same hazard, same fix as the Xsvga `exp` object whose path used to default into a /tmp scratchpad:
# pin the content and fail closed.  Updating the pin is a deliberate act; drifting past it is not.
# Re-pinned 2026-08-19 for the Zorro III track: the driver is now address-agnostic
# (va2000_regs[] for register access, va2000_boards[] still PHYSICAL for d_mmap) and
# takes its aperture size from AutoConfig instead of a 4 MB constant.  That work sits
# on wip/zorro3, which BRANCHED FROM the 8-bit branch -- so the wolf3d 8-bit support
# is still in, and this pin still fails closed if the checkout moves back to main.
# Re-pinned 2026-09-28: wip/zorro3 was fast-forwarded into va2000-amix `main`, so the
# branch note above is history rather than instruction -- `main` now carries the Zorro III
# work.  The content change in this re-pin is SVGAIOCSetMonitorSwitch driving the hardware
# instead of storing the value: Amiga restores passthrough, SVGA replays the stored
# modeline, anything else is EINVAL.  Agreed with the driver line as the one seam every
# RTG driver implements its own way (amix-mail, 2026-09-28).
# Re-pinned 2026-11-15: the va2000-amix fork's `next` (db12baf) computes the mmap page
# frame with `>> PNUMSHFT` and adds the module form behind its own switches; with none of
# those switches and -DVA2000_KVA it compiles to the same va2000_040.o as upstream patched.
# sha256 -> (mode, where it comes from).  "patch" rewrites the literal, "copy" takes the
# file as it is.
PINS = {
    "b542e9019ae37fba2452e6833e77bbe1364298c1d17921255b6b6836364b424b":
        ("patch", "va2000-amix main 7f82edc (upstream)"),
    "340aae5eb3bae5b4bcfce7afb5937fdeb8005a2d1f5b5a7d0e883c9b0bce3643":
        ("copy", "va2000-amix fork next db12baf"),
}
EXPECT_NOTE = ("both carry the 8-bit display mode support wolf3d needs and the Zorro III "
               "address-agnostic work")


def check_provenance():
    import hashlib
    got = hashlib.sha256(open(SRC_C, "rb").read()).hexdigest()
    if got in PINS:
        mode, where = PINS[got]
        print("va2000_modelb: source provenance OK (%s, %s)" % (where, got[:12]))
        return mode
    raise SystemExit(
        "ABORT: %s does not match a pinned source.\n"
        "       expected sha256 one of:\n%s"
        "       got      sha256 %s\n"
        "       %s.\n"
        "       If the va2000-amix checkout moved, restore one of the commits above.\n"
        "       If the driver genuinely changed, re-check the diff and update PINS here\n"
        "       ON PURPOSE -- silently building a different driver into the kernel is exactly the\n"
        "       failure this pin exists to prevent."
        % (SRC_C, "".join("           %s  (%s)\n" % (h, w) for h, (m, w) in PINS.items()),
           got, EXPECT_NOTE))


def main():
    if not os.path.isfile(SRC_C):
        raise SystemExit("ABORT: driver source not found: %s" % SRC_C)
    if not os.path.isfile(SRC_H):
        raise SystemExit("ABORT: driver header not found: %s" % SRC_H)
    mode = check_provenance()

    text = open(SRC_C).read()
    n = text.count(OLD)
    if mode == "copy":
        # No rewrite: the shift is the kernel's PNUMSHFT, 12 under the Model-B headers.
        if n or ">> 11)" in text or text.count(">> PNUMSHFT)") != 1:
            raise SystemExit("ABORT: %s is pinned as PNUMSHFT-only, but it has %d literal "
                             ">>11 site(s) and %d PNUMSHFT shift(s)"
                             % (SRC_C, text.count(">> 11)"), text.count(">> PNUMSHFT)")))
        patched = text
    else:
        if n != 1:
            raise SystemExit(
                "ABORT: expected exactly ONE occurrence of the vanilla >>11 shift "
                "in va2000mmap, found %d.  Upstream source (%s) may have changed "
                "-- update OLD/NEW in this script after re-checking the diff." % (n, SRC_C))
        patched = text.replace(OLD, NEW, 1)
        if patched.count(">> 12)") != 1 or ">> 11)" in patched:
            raise SystemExit("ABORT: post-patch sanity check failed (unexpected >>11/>>12 count)")

    os.makedirs(os.path.dirname(OUT_C), exist_ok=True)
    with open(OUT_C, "w") as f:
        f.write(patched)
    shutil.copyfile(SRC_H, OUT_H)

    if mode == "copy":
        print("  [ok] va2000mmap shifts by PNUMSHFT (1 site), copied unchanged -> %s" % OUT_C)
    else:
        print("  [ok] va2000mmap phystopfn >>11 -> >>12 (1 site) -> %s" % OUT_C)
    print("  [ok] va2000.h copied unmodified -> %s" % OUT_H)
    print("va2000_modelb: %s untouched (read-only); copy in build/" % SRC_C)


if __name__ == "__main__":
    main()
