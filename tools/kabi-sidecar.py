#!/usr/bin/env python3
"""kabi-sidecar.py -- write the kabi sidecar of a finished kernel (docs/contracts/KINFO.md, "The sidecar").

  python3 tools/kabi-sidecar.py KERNEL --family NAME [--pin PIN] [-o OUT]
  python3 tools/kabi-sidecar.py KERNEL --family NAME [--pin PIN] --stand DIR
  python3 tools/kabi-sidecar.py --check KERNEL SIDECAR

One key=value per line, in this order: kabi, family, line, pin, build, size, sha256, loader-min,
root, rootfs.  Every value except family and pin is read from the kernel image itself, so the
sidecar and /dev/kinfo cannot disagree:
  kabi     kinfo's kinfo_kabi string ("static" on a static kernel; the image must carry kinfo)
  build    inituname040's buildid, as uname -m and kinfo show it on the CPU the image is stamped
           for (cputype 60 turns "68040-" into "68060-")
  root     the rows of the controller table sd's init() walks (the relocation of its
           `lea <table>,%a3` and its loop bound): zorro:<mmmm>:<pp> for an AutoConfig id,
           mobo:a3000-wd for the stock A3000 row, mobo:gayle for the Gayle IDE row
  rootfs   the root filesystems the image can mount: ufs (ufs_mountroot), s5 (s5mountroot)
  pin      gcc-<version>-<commit> of gcc-cross-amix; by default its HEAD, refused unless the
           installed m68k-cbm-sysv4-gcc is that commit's wrapper
No timestamps: the same image gives the same bytes.

A module kernel (kinfo_kabi not "static", relink-040-dlm.sh) gets the sidecar of C2-3 version 5
(amix-dlm C3-3 section 3) instead: family must be generic; loader-min=2; root and rootfs as for a
static kernel (through stage 3 the floor's SCSI drivers and filesystems stay built in, and kbootset's
gate 3 reads them); and last, from the image's own AXK1 record (dlm_ident, filled by
relink-040-dlm.sh --fill):
  ident    the record's image offset (from the bind address: .text, .rodata, .data, no padding)
  arena    the arena's image offset and capacity, as the record gives them
  ksym     the symbol block's image offset and size, as the record gives them
The record is checked first: magic, version and length, the check, its kabi tag = kinfo's, line 46,
and the arena and block offsets those of dlm_arena and dlm_ksym in the image.

-o OUT writes the sidecar there (default: KERNEL's directory/kabi when KERNEL is named unix, else
KERNEL.kabi).  --stand DIR lays out the package's files instead: DIR/stand/k46/unix (a copy of
KERNEL) and DIR/stand/k46/kabi.  --check exits 0 when SIDECAR is what this tool writes for KERNEL.
"""
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "src"))
import a4091_sd_rows as rows  # noqa: E402  (the reader of sd's controller table)

LOADER_MIN = 1
LOADER_MIN_DLM = 2
AXK1_MAGIC = 0x41584B31
MOBO_ROWS = {0x0202F003: "mobo:a3000-wd", 0x1DE0A400: "mobo:gayle"}
ROOTFS = (("ufs", "ufs_mountroot"), ("s5", "s5mountroot"))


def die(msg):
    raise SystemExit("kabi-sidecar: " + msg)


def symbols(e):
    out = {}
    for i in range(e.syn):
        s = e.sym(i)
        if s["shndx"] != 0:
            out.setdefault(s["name"], s)
    return out


def data_bytes(e, syms, name, n):
    if name not in syms or e.names[syms[name]["shndx"]] != ".data":
        die("%s: no .data symbol %s" % (e.path, name))
    o = e.sec[".data"]["offset"] + syms[name]["value"]
    return bytes(e.b[o:o + n])


def cstr(b):
    return b.split(b"\0")[0].decode("latin-1")


def image_offset(e, syms, name):
    if name not in syms or e.names[syms[name]["shndx"]] != ".data":
        die("%s: no .data symbol %s" % (e.path, name))
    return sum(e.sec[n]["size"] for n in (".text", ".rodata") if n in e.sec) + syms[name]["value"]


def axk1(e, syms, kabi):
    rec = data_bytes(e, syms, "dlm_ident", 64)
    w = [int.from_bytes(rec[i:i + 4], "big") for i in range(0, 64, 4)]
    if w[0] != AXK1_MAGIC or w[1] != (1 << 16 | 64):
        die("dlm_ident is not an AXK1 version 1 record of 64 bytes")
    if sum(w) & 0xFFFFFFFF:
        die("AXK1 check fails: is the image filled (relink-040-dlm.sh --fill)?")
    if cstr(rec[12:36]) != kabi or w[9] != 46:
        die("AXK1 says kabi %r line %d; kinfo says %r on line 46" % (cstr(rec[12:36]), w[9], kabi))
    if w[10] != image_offset(e, syms, "dlm_arena") or w[12] != image_offset(e, syms, "dlm_ksym"):
        die("AXK1's arena/ksym offsets are not dlm_arena's/dlm_ksym's in this image")
    if not w[11] or w[11] & 0xFFFF or not w[13]:
        die("AXK1 arena capacity 0x%x / block size 0x%x" % (w[11], w[13]))
    return [("ident", "0x%08x" % image_offset(e, syms, "dlm_ident")),
            ("arena", "0x%08x 0x%08x" % (w[10], w[11])),
            ("ksym", "0x%08x 0x%08x" % (w[12], w[13]))]


def default_pin():
    gca = os.path.join(os.path.dirname(os.path.dirname(HERE)), "gcc-cross-amix")
    try:
        head = subprocess.run(["git", "-C", gca, "rev-parse", "--short=7", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
        wrapper = open(os.path.join(gca, "amix-gcc-wrapper.sh")).read().replace("@TARGET@", "m68k-cbm-sysv4")
    except (OSError, subprocess.CalledProcessError):
        die("cannot read gcc-cross-amix at %s; give --pin" % gca)
    cc = shutil.which("m68k-cbm-sysv4-gcc")
    if not cc or open(cc).read() != wrapper:
        die("the installed m68k-cbm-sysv4-gcc (%s) is not gcc-cross-amix %s's wrapper; give --pin" % (cc, head))
    return "gcc-2.7.2.3-" + head


def sidecar(kernel, family, pin):
    e = rows.Elf(kernel)
    e.path = kernel
    syms = symbols(e)
    if "kinfoopen" not in syms or "kinfo_kabi" not in syms:
        die("%s does not carry kinfo (relink-040-kinfo.sh)" % kernel)
    kabi = cstr(data_bytes(e, syms, "kinfo_kabi", 24))
    build = cstr(data_bytes(e, syms, "buildid", 17)).strip()
    cpu = int.from_bytes(data_bytes(e, syms, "cputype", 4), "big")
    if not build.startswith("68040-") or cpu not in (40, 60):
        die("buildid %r / cputype %d is not a stamped image of this line" % (build, cpu))
    if cpu == 60:
        build = "68060-" + build[6:]
    if build.endswith("000000-00"):
        die("buildid %r is the unstamped literal" % build)
    raw = open(kernel, "rb").read()
    head = [("kabi", kabi), ("family", family), ("line", "k46"), ("pin", pin), ("build", build),
            ("size", str(len(raw))), ("sha256", hashlib.sha256(raw).hexdigest())]
    axk = None
    if kabi != "static":
        if family != "generic":
            die("a module kernel (kabi %s) is family generic, not %r" % (kabi, family))
        axk = axk1(e, syms, kabi)
    tname, bound, table, _ = rows.read_table(e)
    keys = []
    for ident, _q, _n in table:
        if ident in MOBO_ROWS:
            k = MOBO_ROWS[ident]
        elif ident >> 16 and ident & 0xFFFF <= 0xFF:
            k = "zorro:%04x:%02x" % (ident >> 16, ident & 0xFF)
        else:
            die("%s row id 0x%08x is neither an AutoConfig id nor a known motherboard row" % (tname, ident))
        if k not in keys:
            keys.append(k)
    fs = [n for n, s in ROOTFS if s in syms]
    if not fs:
        die("no root filesystem in %s" % kernel)
    lines = head + [
        ("loader-min", str(LOADER_MIN if axk is None else LOADER_MIN_DLM)),
        ("root", ",".join(keys)),
        ("rootfs", ",".join(fs)),
    ] + (axk or [])
    return "".join("%s=%s\n" % kv for kv in lines)


def main():
    a = sys.argv[1:]
    if a[:1] == ["--check"]:
        if len(a) != 3:
            die("usage: --check KERNEL SIDECAR")
        have = open(a[2]).read()
        fam = dict(l.split("=", 1) for l in have.splitlines() if "=" in l)
        want = sidecar(a[1], fam.get("family", ""), fam.get("pin", ""))
        print("[ok] %s matches %s" % (a[2], a[1]) if have == want else "[FAIL] %s is not the sidecar of %s" % (a[2], a[1]))
        sys.exit(0 if have == want else 1)
    kernel, family, pin, out, stand = None, None, None, None, None
    while a:
        x = a.pop(0)
        if x == "--family":
            family = a.pop(0)
        elif x == "--pin":
            pin = a.pop(0)
        elif x == "-o":
            out = a.pop(0)
        elif x == "--stand":
            stand = a.pop(0)
        elif kernel is None and not x.startswith("-"):
            kernel = x
        else:
            die("unknown argument %s" % x)
    if not kernel or not family:
        raise SystemExit(__doc__)
    text = sidecar(kernel, family, pin or default_pin())
    if stand:
        d = os.path.join(stand, "stand", "k46")
        os.makedirs(d, exist_ok=True)
        shutil.copyfile(kernel, os.path.join(d, "unix"))
        out = os.path.join(d, "kabi")
    elif not out:
        out = os.path.join(os.path.dirname(kernel), "kabi") if os.path.basename(kernel) == "unix" else kernel + ".kabi"
    open(out, "w").write(text)
    sys.stdout.write(text)
    print("-> %s" % out)


main()
