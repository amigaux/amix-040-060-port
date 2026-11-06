#!/usr/bin/env python3
"""patch_audio_replies.py -- /dev/audio answers each ioctl once and plays each byte once.
Applied to a build-time copy of the AMIX 2.1c audio driver (usr/sys/amiga/driver/audio.c)
after amix-paula's three patchers (safeclose, initwait, paula), in both kernel lines.
Usage: patch_audio_replies.py audio.c          patch it in place
       patch_audio_replies.py --selftest audio.c   check it on copies; audio.c is left alone

1. One reply per ioctl.  In audioioctl, the AUDIO_VOLUME and AUDIO_PERIOD cases send their
   M_IOCACK or M_IOCNAK with putnext and then break to the common tail, which turns the same
   message into an M_IOCACK with error 0 and sends it again.  Every such request is answered
   twice, and a refusal (EINVAL for a wrong length) arrives as success.  Ours: the four breaks
   become returns.  The two acks also get ioc_rval and ioc_error set to 0, which only the tail
   did: on the transparent path the message is the M_IOCDATA reply, whose cp_pad1 and cp_pad2
   lie where ioc_error and ioc_rval are.
2. A partly copied message moves on.  When audiointr refills a channel buffer from a message
   that does not fit (more than the 8 KiB buffer holds), it keeps the message without advancing
   b_rptr, so the next refill copies the same bytes again: a write longer than the free buffer
   replays stretches of itself.  postaudio advances b_rptr after its copy; ours does the same
   in both refill places.
3. No data block, no pullup.  An I_STR with ic_len 0 reaches audioioctl with b_cont NULL, and the
   VOLUME and PERIOD cases called pullupmsg(b_cont) before testing it; pullupmsg does not test
   for NULL, and low memory is mapped in kernel mode, so it read and wrote there.  Ours calls
   pullupmsg only when there is a block, and the test after it refuses the request (EINVAL).

Commodore's text is not in this file.  Each place is found as amix-paula's patchers find theirs:
the SHA-256 of its lines exactly as the file has them, matched the expected number of times.
The whole input must be the one both lines make from amix-paula's patchers (IN), and the
result must be OUT; anything else is refused, so a second run is refused too.

Copyright (c) 2026 Jussi Alanärä.  MIT licence, see LICENSE in kernel/k30.
"""
import hashlib
import os
import sys
import tempfile

IN = "1f43c5ff6558bf6583bcc3525b456bf3560e2bcf6100f5c736b0aa0221b260cc"
OUT = "3f434f3507e1044ca794706a2de3a05c99ddefbcda6cd8e1b9abc6e60bc24fef"

T = "\t\t    "		# the ioctl branch bodies' and the refill's indent
REPLY = "/* the one reply is sent (amix) */"


def nak(b):	# VOLUME and PERIOD: the refusal's putnext, then break
    return b[:-1] + [T + "return;\t" + REPLY]


def ack(b):	# VOLUME and PERIOD: the ack's putnext, a blank line, the else's brace, the case's break
    return [b[0], "\t\tiocbp->ioc_rval = 0;", "\t\tiocbp->ioc_error = 0;", b[1], b[2], b[3],
            "\t    return;\t" + REPLY]


def keep(b):	# the refill from the kept message: all of it copied, or not
    return b + [T + "else\t/* the copied part is played once (amix) */", "\t\t\tacl->mp->b_rptr += size;"]


def guard(b):	# VOLUME and PERIOD: the I_STR data pulled up
    return ["\t\tif (mp->b_cont)\t/* ic_len 0 sends no block (amix) */", T + b[0].lstrip("\t")]


def park(b):	# the refill from the queue: the message does not fit and is kept
    return b[:2] + ["\t\t\t    mp->b_rptr += size;\t/* the copied part is played once (amix) */"] + b[2:]


EDITS = [	# what, lines, sha256 of the lines, times expected, the change
    ("audioioctl: a refusal sent, then break", 5,
     "6fb314fc8c6e5ff1b89c3ef1c324d28a1feb32c7892652d7184c3fe70c7aa49a", 2, nak),
    ("audioioctl: an ack sent, then break", 5,
     "03e880e641a4988ce5ff53ad9891e0edf2e1c8e0352c43df6a274cb446667a6e", 2, ack),
    ("audiointr: the kept message refilled", 5,
     "659b0b1f3d8987f0ade6dec1d76dfd4f35bd8e78b2684164a1a3c3e73dd5be6e", 1, keep),
    ("audiointr: a queued message that does not fit", 3,
     "a22fadd17ea332d58a417d3fce582e35503a461f4f55a4886f347022d006f019", 1, park),
    ("audioioctl: the I_STR data pulled up", 1,
     "539998a30db909d6860cda91c55b89e479298ae19ce87b5a9c39304a0c547920", 2, guard),
]
INMSG, OUTMSG, PLACEMSG = "is not the one amix-paula's three patchers make", "is not the pinned one", "fingerprint found"


def split(text):	# at newlines only: the file has form feeds between functions
    return text.split("\n")


def patch(text, pin=IN, out=OUT):	# pin or out None: that check is not made (the selftest's own use)
    if pin is not None and hashlib.sha256(text.encode("latin-1")).hexdigest() != pin:
        raise ValueError("audio.c is not the one amix-paula's three patchers make (sha256 %s), "
                         "or it is patched already" % IN[:16])
    lines = split(text)
    todo = []
    for what, n, digest, count, change in EDITS:
        hits = [i for i in range(len(lines) - n + 1)
                if hashlib.sha256("\n".join(lines[i:i + n]).encode("latin-1")).hexdigest() == digest]
        if len(hits) != count:
            raise ValueError("%s: fingerprint found %d times, expected %d" % (what, len(hits), count))
        todo += [(i, n, change) for i in hits]
    for i, n, change in sorted(todo, reverse=True):
        lines[i:i + n] = change(lines[i:i + n])
    res = "\n".join(lines)
    if out is not None and hashlib.sha256(res.encode("latin-1")).hexdigest() != out:
        raise ValueError("the result is not the pinned one (sha256 %s)" % out[:16])
    return res, len(todo)


def read(path):
    with open(path, encoding="latin-1", newline="") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="latin-1", newline="") as f:
        f.write(text)


def selftest(path):
    """each check shown to refuse on its own, by its own message"""
    text = read(path)
    out, n = patch(text)
    bad = []
    refused = []

    def refuse(name, msg, t, **kw):
        try:
            patch(t, **kw)
            bad.append("patched %s" % name)
        except ValueError as e:
            if msg in str(e):
                refused.append(name)
            else:
                bad.append("%s: refused for another reason: %s" % (name, e))

    more = text + "\n"	# every place still there, the whole file not the pinned one
    refuse("the result again", INMSG, out)
    refuse("one byte changed", INMSG, text[:100] + chr(ord(text[100]) ^ 1) + text[101:])
    refuse("empty", INMSG, "")
    refuse("a line more, by the input pin alone", INMSG, more, out=None)
    refuse("a line more, by the output pin alone", OUTMSG, more, pin=None)
    lines = split(text)	# each place on its own: one of its lines changed, both pins off
    for what, k, digest, count, change in EDITS:
        i = [i for i in range(len(lines) - k + 1)
             if hashlib.sha256("\n".join(lines[i:i + k]).encode("latin-1")).hexdigest() == digest][0]
        refuse(what + " changed", "%s %d times" % (PLACEMSG, count - 1),
               "\n".join(lines[:i] + [lines[i] + " "] + lines[i + 1:]), pin=None, out=None)
    d = tempfile.mkdtemp()
    p = os.path.join(d, "audio.c")
    try:
        write(p, text)
        main(["patch_audio_replies.py", p])
        if hashlib.sha256(read(p).encode("latin-1")).hexdigest() != OUT:
            bad.append("the file written is not the pinned result")
    finally:
        os.remove(p)
        os.rmdir(d)
    for b in bad:
        print("  [FAIL] " + b)
    print("patch_audio_replies selftest: %d places, result %s; refused (%d): %s; %s"
          % (n, OUT[:16], len(refused), ", ".join(refused), "FAIL" if bad else "ok"))
    return 1 if bad else 0


def main(argv):
    if len(argv) == 3 and argv[1] == "--selftest":
        return selftest(argv[2])
    if len(argv) != 2:
        sys.exit("usage: patch_audio_replies.py [--selftest] audio.c")
    try:
        out, n = patch(read(argv[1]))
    except ValueError as e:
        sys.exit("[FAIL] %s" % e)
    write(argv[1], out)
    print("      [ok] audio.c: one reply per volume/period ioctl, refills move on, no pullup of no block (%d places)" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
