#!/usr/bin/env python3
# The block lookup of cut 68060-261031-52: cut.sh puts it in the run's port tree as tools/blocks.py.  The tree's own
# blocks.py maps `git config user.email` to a build-id block, so the stamp would depend on who rebuilds the cut;
# here `buildseq` answers the block this cut was stamped from (50-99, CONTRACTS.md; as -51), whoever runs it.
import sys
if sys.argv[1:] == ["buildseq"]:
    print("50 99")
    sys.exit(0)
sys.exit("blocks.py (cut 68060-261031-52): only `buildseq` is answered here")
