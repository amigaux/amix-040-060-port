#!/usr/bin/env python3
# The build-id stamper shim of cut 68060-261030-51 (as -61's, kerntools KT-41): cut.sh puts it in the run's port
# tree as src/stamp_buildid.py, the tree's own stamper beside it as stamp_buildid.real.py.  Every relink calls the
# stamper; only the fpe pass, run with STAMP_BUILDID=stamp, stamps, so the cut carries exactly one stamp.
import os, sys
if os.environ.get("STAMP_BUILDID", "skip") == "stamp":
    real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stamp_buildid.real.py")
    os.execv(sys.executable, [sys.executable, real] + sys.argv[1:])
print("stamp_buildid: SKIPPED for %s (scratch tree copy; STAMP_BUILDID=stamp stamps -- kerntools KT-41)"
      % (sys.argv[1] if len(sys.argv) > 1 else "?"))
