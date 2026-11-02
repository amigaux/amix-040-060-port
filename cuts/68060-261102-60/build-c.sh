#!/bin/sh
# cut 68060-261102-60 (as -59): -58's build-c.sh without the F4 instrument passes: no relink-040-f4arms.sh --ufault (the fatal
# user-fault census) and no relink-040-f6.sh --kvd --swa (the vector-dispatch census and the swapadd operand latch);
# without --cache, --ufault was f4arms' only arm in this chain and --kvd --swa f6's only two.  The base no longer
# carries the user-trap latch either (relink-040.sh DIAG106=0), so patch_trapdiag_off.py has nothing to do.
# Its directories from the environment (W = the cut's run root, set by cut.sh; PAULA = amix-paula with 62fdcab); the
# module core from the amix clone's kernel/dlm at 46c269c.
# F4=1 runs the two passes as -58 did (on this base they need DIAG106=1 for the latch they chain in front of).
# k46 paula cut -61 (2026-10-28): -59's recipe at port d76a7f0 = relink-040-audio.sh with amix-paula 62fdcab (safeclose, initwait, paula).
# k46 paula cut (2026-10-28): the -51 recipe (port 87b8a88) at port b5f9bc1 = amix-dlm e45b061, kabi k46.1.3,
# with relink-040-audio.sh (amix-paula d82e32d) between f6 and rth1 (AUDIO=0 leaves it out: the refusal control).
# k46 re-cut (2026-10-28): the -91 recipe (port 88dcfc0, base 284154a3) with the dlm core at amix-dlm 7b07bce.
# Re-cut of 2026-10-27 (port 88dcfc0, fresh tree, base rebuilt): the k46 cut without ufs and s5 (CARVE=1, default; CARVE=0 = the same chain uncarved, the control), port k46-module + relink-040-carve.sh.
# Derived from the kern46m dry build: the -75 recipe (no static z3660scsi) at amix-dlm 178a47b (core 0001-0041, DDI 1.2 DMA,
# kabi k46.1.2, the arena 16-aligned) without the z3660 pass (Z3660=1 puts it back);
# with the four-card sd/dd/ct pass after dd; the dlm pass adds the halt hook, the sd seam, rth1_nomarc -> dlm_marc_root, bdevsw[20] freed.
# SD4A=1 / SD4I=1 add the a4091 / ide passes (the three-controller proof, not of record).
# SD4I=1 adds the Gayle IDE pass after the a4091 one (a third controller, rank 4).
# SD4=0 rebuilds -61's chain from this tree (the control: every stage = -61's).
# The base is relink-040.sh's output with cputype a size-4 object (build/b-new 284154a3, as -54).
#   base -> dd -> z3660 Z3660_NET=off -> f4arms -> f6 -> rth1 DLM=1 -> kinfo DLM=1 -> dlm -> fpe (stamped)
# Steps 9-10 (relink-040-dlm.sh --fill, with mkabi.py) run in post-m.sh after the support-probe inject.
# Not packaged.  usage: build-m.sh [tag] [base]   (tag default m, base default build/b-new)
set -e
W=${W:?}; PAULA=${PAULA:?}
export STAMP_BUILDID_CPU=60 AMIX_ALLOW_UNKNOWN_STOCK=1 DLM_REPO=$W/amix/kernel/dlm DLM_REV=46c269c PAULA_REPO=$PAULA PAULA_REV=62fdcab
unset IDE_ORDER IDE_REPO IDE_REV ZPROF_EXTRA DLM_KABI KINFO_KABI STAMP_BUILDID
T=${1:-m}; B=build; BASE=${2:-$B/b-new}; L=$W/log/$T; K=$W/kernels/$T; mkdir -p $L $K; cd $W/port
if [ "${CARVE:-1}" = 1 ]; then sh relink-040-carve.sh $BASE $B/$T-carve > $L/00-carve.log 2>&1; BASE=$B/$T-carve; fi
sh relink-040-dd.sh $BASE $B/$T-dd > $L/0-dd.log 2>&1
Z0=$B/$T-dd
if [ "${SD4:-1}" = 1 ]; then sh relink-040-sd4card.sh $B/$T-dd $B/$T-sd4 > $L/0b-sd4card.log 2>&1; Z0=$B/$T-sd4; fi
if [ "${Z3660:-0}" = 1 ]; then Z3660_NET=off Z3660_SCSI_REV=86e6cd7 sh relink-040-z3660.sh $Z0 $B/$T-f7base > $L/1-z3660.log 2>&1
else cp $Z0 $B/$T-f7base; echo "no z3660 pass: the Z3660 root comes from a module" > $L/1-z3660.log; fi
if [ "${SD4A:-0}" = 1 ]; then mv $B/$T-f7base $B/$T-z3660; A4091_REPO=${A4091_REPO:?} sh relink-040-a4091.sh $B/$T-z3660 $B/$T-f7base > $L/1b-a4091.log 2>&1; fi
if [ "${SD4I:-0}" = 1 ]; then mv $B/$T-f7base $B/$T-a4091; IDE_REPO=${IDE_REPO:?} sh relink-040-ide.sh $B/$T-a4091 $B/$T-f7base > $L/1c-ide.log 2>&1; fi
if [ "${F4:-0}" = 1 ]; then
	if [ "${Z3660:-0}" = 1 ]; then F4C="--cache 60"; else F4C=; fi; sh relink-040-f4arms.sh --ufault $F4C $B/$T-f7base $B/$T-f7uft > $L/2-f4arms.log 2>&1
	sh relink-040-f6.sh --kvd --swa $B/$T-f7uft $B/$T-f7vs > $L/3-f6.log 2>&1
elif [ "${Z3660:-0}" = 1 ]; then
	sh relink-040-f4arms.sh --cache 60 $B/$T-f7base $B/$T-f7uft > $L/2-f4arms.log 2>&1; cp $B/$T-f7uft $B/$T-f7vs
	echo "no f6 pass (F4=0)" > $L/3-f6.log
else
	cp $B/$T-f7base $B/$T-f7uft; cp $B/$T-f7uft $B/$T-f7vs
	echo "no f4arms pass (F4=0; no --cache arm without the static z3660)" > $L/2-f4arms.log; echo "no f6 pass (F4=0)" > $L/3-f6.log
fi
if [ "${AUDIO:-1}" = 1 ]; then sh relink-040-audio.sh $B/$T-f7vs $B/$T-audio > $L/3b-audio.log 2>&1; R1=$B/$T-audio
else R1=$B/$T-f7vs; echo "no audio pass (AUDIO=0)" > $L/3b-audio.log; fi
DLM=1 sh relink-040-rth1.sh $R1 $B/$T-rth1 > $L/4-rth1.log 2>&1
DLM=1 sh relink-040-kinfo.sh $B/$T-rth1 $B/$T-kinfo > $L/5-kinfo.log 2>&1
sh relink-040-dlm.sh $B/$T-kinfo $B/$T-dlm > $L/6-dlm.log 2>&1
STAMP_BUILDID=stamp sh relink-040-fpe.sh $B/$T-dlm $B/$T-fpe > $L/7-fpe.log 2>&1
cp $B/$T-fpe $K/unix-fpe
for f in ${2:-$B/b-new} $(ls $B/$T-carve 2>/dev/null) $B/$T-dd $(ls $B/$T-sd4 $B/$T-z3660 $B/$T-a4091 2>/dev/null) $B/$T-f7base $B/$T-f7uft $B/$T-f7vs $(ls $B/$T-audio 2>/dev/null) $B/$T-rth1 $B/$T-kinfo $B/$T-dlm $B/$T-fpe; do
	echo "$(sha256sum $f | cut -c1-16)  $(basename $f)"; done
echo DONE
